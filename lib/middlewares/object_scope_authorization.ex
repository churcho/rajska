defmodule Rajska.ObjectScopeAuthorization do
  @moduledoc """
  Absinthe Phase to perform object scoping.

  Authorizes all Absinthe's [objects](https://hexdocs.pm/absinthe/Absinthe.Schema.Notation.html#object/3) requested in a query by checking the value of the field defined in each object meta `scope`.

  ## Usage

  [Create your Authorization module and add it and ObjectScopeAuthorization to your Absinthe Pipeline](https://hexdocs.pm/rajska/Rajska.html#module-usage). Then set the scope of an object:

  ```elixir
  object :user do
    meta :scope_by, :id
    meta :rule, :default

    field :id, :integer
    field :email, :string
    field :name, :string

    field :company, :company
  end

  object :company do
    meta :scope_by, :user_id
    meta :rule, :default

    field :id, :integer
    field :user_id, :integer
    field :name, :string
    field :wallet, :wallet
  end

  object :wallet do
    meta :scope_by, :id
    meta :rule, :read_only

    field :id, :integer
    field :total, :integer
  end
  ```

  To define custom rules for the scoping, use `c:Rajska.Authorization.has_user_access?/3`. For example:

  ```elixir
  defmodule Authorization do
    use Rajska,
      valid_roles: [:user, :admin]

    @impl true
    def has_user_access?(%{role: :admin}, _, _scoped_struct, _rule), do: true
    def has_user_access?(%{id: user_id}, %User{id: id}, _rule) when user_id === id, do: true
    def has_user_access?(_current_user, %User{}, _rule), do: false
  end
  ```

  Keep in mind that the `field_value` provided to `has_user_access?/3` can be `nil`. This case can be handled as you wish.
  For example, to not raise any authorization errors and just return `nil`:

  ```elixir
  defmodule Authorization do
    use Rajska,
      valid_roles: [:user, :admin]

    @impl true
    def has_user_access?(%User{role: :admin}, _scoped_struct, _rule), do: true
    def has_user_access?(%User{id: user_id}, %User{id: id}, _rule) when user_id === id, do: true
    def has_user_access?(_current_user, %User{}, _rule), do: false
  end
  ```

  The `rule` keyword is not mandatory and will be pattern matched in `has_user_access?/3`:

  ```elixir
  defmodule Authorization do
    use Rajska,
      valid_roles: [:user, :admin]

    @impl true
    def has_user_access?(%{id: user_id}, %Wallet{}, :read_only), do: true
    def has_user_access?(%{id: user_id}, %Wallet{}, :default), do: false
  end
  ```

  This way different rules can be set to the same struct.
  See `Rajska.Authorization` for `rule` default settings.
  """

  alias Absinthe.{Blueprint, Phase, Type}
  alias Rajska.Introspection
  use Absinthe.Phase

  @spec run(Blueprint.t() | Phase.Error.t(), Keyword.t()) :: {:ok, map}
  def run(%Blueprint{execution: execution} = bp, _options \\ []) do
    {:ok, %{bp | execution: process(execution)}}
  end

  defp process(%{validation_errors: [], result: result} = execution), do: %{execution | result: result(result, execution.context)}
  defp process(execution), do: execution

  # Introspection
  defp result(%{emitter: %{schema_node: %{identifier: identifier}}} = result, _context)
  when identifier in [:query_type, nil] do
    result
  end

  # Root
  defp result(%{fields: fields, emitter: %{schema_node: %{identifier: identifier}}} = result, context)
  when identifier in [:query, :mutation, :subscription] do
    %{result | fields: walk_result(fields, context)}
  end

  # Object
  defp result(%{fields: fields, emitter: %{schema_node: schema_node} = emitter, root_value: root_value} = result, context) do
    type = Introspection.get_object_type(schema_node.type)
    scope_by = get_scope_by!(type)
    scope = get_scope!(scope_by, result)

    default_rule = Rajska.apply_auth_mod(context, :default_rule)
    rule = Type.meta(type, :rule) || default_rule

    case authorized?(scope, scope_by, root_value, context, rule, type) do
      true -> %{result | fields: walk_result(fields, context)}
      false -> Map.put(result, :errors, [error(emitter)])
    end
  end

  # List
  defp result(%{values: values} = result, context) do
    %{result | values: walk_result(values, context)}
  end

  # Leafs
  defp result(result, _context), do: result

  defp walk_result(fields, context, new_fields \\ [])

  defp walk_result([], _context, new_fields), do: Enum.reverse(new_fields)

  defp walk_result([field | fields], context, new_fields) do
    new_fields = [result(field, context) | new_fields]
    walk_result(fields, context, new_fields)
  end

  defp get_scope_by!(object) do
    general_scope_by = Type.meta(object, :scope_by)
    object_scope_by = Type.meta(object, :scope_object_by)

    case {general_scope_by, object_scope_by} do
      {nil, nil} -> raise "No meta scope_by or scope_object_by defined for object #{inspect object.identifier}"
      {nil, object_scope_by} -> object_scope_by
      {general_scope_by, nil} -> general_scope_by
      {_, _} -> raise "Error in #{inspect object.identifier}. If scope_object_by is defined, then scope_by must not be defined"
    end
  end

  defp get_scope!(false, _result), do: false
  defp get_scope!(_scope_by, %{root_value: %scope{}}), do: scope
  defp get_scope!(_scope_by, %{emitter: %{schema_node: schema_node}, root_value: root_value}) do
    type = Introspection.get_object_type(schema_node.type)
    raise "Expected a Struct for object #{inspect(type.identifier)}, got #{inspect(root_value)}"
  end

  defp authorized?(_scope, false, _values, _context, _, _object), do: true

  defp authorized?(scope, scope_field, values, context, rule, _object) do
    field_value = Map.get(values, scope_field)

    Rajska.apply_auth_mod(context, :has_context_access?, [context, scope, {scope_field, field_value}, rule])
  end

  defp error(%{source_location: location, schema_node: %{type: type}}) do
    %Phase.Error{
      phase: __MODULE__,
      message: "Not authorized to access object #{Introspection.get_object_type(type).identifier}",
      locations: [location]
    }
  end
end
