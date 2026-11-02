# Each FxX module is written out as the fixture's Elixir.X.beam: the reader takes a module's name
# from its file name, and compiling a real `Kernel` or `Enum` would replace the compiler's own.
defmodule FxKernel do
  @doc "Kernel.then/2"
  defmacro then(value, fun), do: {value, fun}
  @doc "Kernel.put_elem/3"
  def put_elem(tuple, index, value), do: {tuple, index, value}
  def function_exported?(module, function, arity), do: {module, function, arity}
end

defmodule FxEnum do
  @type t :: term
  @doc "Enum.map/2"
  def map(enumerable, fun), do: {enumerable, fun}
  def count(enumerable), do: enumerable
  def count(enumerable, fun), do: {enumerable, fun}
  @doc false
  def __hidden__(x), do: x
end

defmodule FxString do
  @type t :: binary
  def upcase(string), do: string
end

defmodule FxMapSet do
  defstruct map: %{}
  def new, do: %{}
end

defmodule FxAssertions do
  defmacro assert(assertion), do: assertion
  defmacro assert(value, message), do: {value, message}
  defmacro refute(assertion), do: assertion
end

defmodule FxCallbacks do
  defmacro setup(block), do: block
  def on_exit(fun), do: fun
end

defmodule FxCase do
  defmacro describe(message, block), do: {message, block}
  defmacro test(message), do: message
  defmacro test(message, block), do: {message, block}
  defmacro __using__(_opts), do: nil
end

defmodule FxCaseTemplate do
  defmacro using(block), do: block
  defmacro __using__(_opts), do: nil
end

defmodule FxDocTest do
  defmacro doctest(module), do: module
end

defmodule FxNoDocs do
  def plain(a, b), do: {a, b}
  defmacro shaped(a), do: a
end
