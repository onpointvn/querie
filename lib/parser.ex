defmodule Querie.ParseContext do
  defstruct valid?: true,
            filter_params: [],
            sort_params: [],
            params: [],
            filter_data: [],
            sort_data: [],
            errors: [],
            schema: %{}
end

defmodule Querie.Parser do
  alias Querie.SchemaHelpers
  alias Querie.ParseContext

  @supported_ops ~w(lt gt ge le is ne in contains icontains between ibetween sort has ref like ilike)

  @doc """
  Parse params and return
  {:ok, filter}
  {:error, errors} errors is a list of tuple [{field, message}]

  Sample schema
  %{
  inserted_at: :date,
  count: {:range, :integer},
  is_active: :boolean,
  name: :string
  }
  """
  def parse(schema, raw_params) do
    raw_params
    |> split_key_and_operator
    |> parse_with_schema(schema)
  end

  def parse_with_schema(params, schema) do
    params
    |> new_context(schema)
    |> parse_filter
    |> parse_sort
    |> finalize_result
  end

  defp split_key_and_operator({key, value}) do
    case String.split(key, "__") do
      [field, operator] ->
        case operator do
          "ref" ->
            {field, {:ref, split_key_and_operator(value)}}

          op when op in @supported_ops ->
            {field, {String.to_atom(op), value}}

          _ ->
            nil
        end

      [field] ->
        {field, {:is, value}}

      _ ->
        nil
    end
  end

  defp split_key_and_operator(params) do
    params
    |> Enum.map(&split_key_and_operator/1)
    |> Enum.reject(&is_nil(&1))
  end

  defp new_context(params, schema) do
    sort_params = Enum.filter(params, fn {_, {op, _}} -> op == :sort end)
    filter_params = params -- sort_params

    %ParseContext{sort_params: sort_params, filter_params: filter_params, schema: schema}
  end

  defp parse_filter(context) do
    data = cast_schema(context.schema, context.filter_params)

    errors = collect_error(data)

    if length(errors) > 0 do
      struct(context, valid?: false, errors: errors)
    else
      struct(context, filter_data: collect_data(data))
    end
  end

  @doc """
  cast value based on operator and schema  field declaration
  if field is not define, skip it
  if field cast return skip then skip it too
  """
  def cast_schema(schema, params) do
    params
    |> Enum.map(fn {column, {operator, _value}} = field ->
      with field_def <- SchemaHelpers.get_field(schema, column),
           {:field_def_nil, false} <- {:field_def_nil, is_nil(field_def)},
           {:ok, casted_value} <- cast_field(field, field_def) do
        # use String.to_existing_atom, here we make sure the column atom existed
        {:ok, {String.to_existing_atom(column), {operator, casted_value}}}
      else
        {:field_def_nil, true} -> nil
        :skip -> nil
        _ -> {:error, {column, "is invalid"}}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # skip empty value
  defp cast_field({_, {_, ""}}, _), do: :skip

  # cast nested schema
  defp cast_field({_, {:ref, raw_value}}, {_, _, opts}) do
    with {:ok, schema} <- Keyword.fetch(opts, :schema),
         {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, casted_value} <- parse_with_schema(raw_value, schema) do
      opts = Keyword.drop(opts, [:schema])
      {:ok, {model, casted_value, opts}}
    end
  end

  # if between operator, cast value range
  defp cast_field({_, {operator, raw_value}}, {_, type, opts})
       when operator in ~w(between ibetween)a do
    Querie.Caster.cast({:range, type}, raw_value, opts)
  end

  defp cast_field({_, {_, raw_value}}, {_, type, opts}) do
    Querie.Caster.cast(type, raw_value, opts)
  end

  # parse sort criteria
  defp parse_sort(%{valid?: true} = context) do
    validation_data =
      context.sort_params
      |> Enum.map(fn {column, {:sort, direction}} ->
        with {_, true} <- {:column, column in SchemaHelpers.fields(context.schema)},
             {_, true} <- {:direction, direction in ~w(asc desc)} do
          {:ok, {String.to_existing_atom(column), {:sort, String.to_atom(direction)}}}
        else
          {:column, _} -> {:error, {column, "is not sortable"}}
          {:direction, _} -> {:error, {column, "sort direction is invalid"}}
        end
      end)

    errors = collect_error(validation_data)

    if length(errors) > 0 do
      struct(context, valid?: false, errors: errors)
    else
      sort_data =
        collect_data(validation_data)
        |> Enum.map(fn {column, {_, direction}} -> {column, direction, nil} end)

      defautl_sort = get_sort_options(context.schema)

      sort_data = merge_sort_option(sort_data, defautl_sort)
      struct(context, sort_data: sort_data)
    end
  end

  defp parse_sort(context), do: context

  defp get_sort_options(schema) do
    Enum.reduce(schema, [], fn {column, opts}, acc ->
      with true <- is_list(opts) do
        [{column, Keyword.get(opts, :sort_default), Keyword.get(opts, :sort_priority)} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reject(fn {_, default, order} -> is_nil(default) and is_nil(order) end)
  end

  # each sort field is a tuple of {column, direction, priority}
  # this function merge default sort and user_defined sort
  # then remove duplicated line and sort by priority smallest first
  # then build tuple {column, direction} for each field
  defp merge_sort_option(user_defined, default) do
    # get sort priority
    user_defined =
      user_defined
      |> Enum.map(fn {column, dir, _} = item ->
        case Enum.find(default, &(elem(&1, 0) == column)) do
          {_, _, priority} -> {column, dir, priority}
          _ -> item
        end
      end)

    (user_defined ++ default)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.map(fn {k, v, _} -> {k, v} end)
  end

  defp finalize_result(%{valid?: true} = context) do
    {:ok, context.filter_data ++ [{:_sort, context.sort_data}]}
  end

  defp finalize_result(%{valid?: false} = context) do
    {:error, context.errors}
  end

  defp collect_error(data) do
    Enum.reduce(data, [], fn {status, field}, acc ->
      if status == :error do
        [field | acc]
      else
        acc
      end
    end)
  end

  defp collect_data(data) do
    Enum.reduce(data, [], fn {status, field}, acc ->
      if status == :ok do
        [field | acc]
      else
        acc
      end
    end)
  end
end
