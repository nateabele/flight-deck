# Regenerates tests/fixtures/elixir-home (a fake Elixir root for tests/elixir_packages.rs):
#   elixirc -o /tmp/fx-ebin fixtures.ex && elixir build.exs /tmp/fx-ebin ../elixir-home
# Each FxX module becomes Elixir.X.beam with only the chunks the reader looks at (AtU8, ExpT and,
# except for NoDocs, Docs), its docs' source paths replaced by a neutral one.
[ebin, out] = System.argv()
map = %{
  "FxKernel" => {"elixir", "Kernel", true},
  "FxEnum" => {"elixir", "Enum", true},
  "FxString" => {"elixir", "String", true},
  "FxMapSet" => {"elixir", "MapSet", true},
  "FxNoDocs" => {"elixir", "NoDocs", false},
  "FxAssertions" => {"ex_unit", "ExUnit.Assertions", true},
  "FxCallbacks" => {"ex_unit", "ExUnit.Callbacks", true},
  "FxCase" => {"ex_unit", "ExUnit.Case", true},
  "FxCaseTemplate" => {"ex_unit", "ExUnit.CaseTemplate", true},
  "FxDocTest" => {"ex_unit", "ExUnit.DocTest", true}
}
for app <- ["elixir", "ex_unit"] do
  dir = Path.join([out, "lib", app, "ebin"])
  File.mkdir_p!(dir)
  File.write!(Path.join(dir, "#{app}.app"), ~s|{application,#{app},[{description,"fixture"},{vsn,"1.99.0"}]}.\n|)
end
for {fx, {app, name, docs?}} <- map do
  bin = File.read!(Path.join(ebin, "Elixir.#{fx}.beam"))
  wanted = if docs?, do: [~c"AtU8", ~c"ExpT", ~c"Docs"], else: [~c"AtU8", ~c"ExpT"]
  {:ok, {_, chunks}} = :beam_lib.chunks(bin, wanted)
  chunks =
    Enum.map(chunks, fn
      {~c"Docs", d} ->
        {:docs_v1, a, l, f, md, meta, docs} = :erlang.binary_to_term(d)
        meta = Map.put(meta, :source_path, ~c"fixtures.ex")
        docs = Enum.map(docs, fn {k, an, s, doc, m} -> {k, an, s, doc, Map.drop(m, [:source_path])} end)
        {~c"Docs", :erlang.term_to_binary({:docs_v1, a, l, f, md, meta, docs}, [:compressed])}
      c -> c
    end)
  {:ok, out_bin} = :beam_lib.build_module(chunks)
  File.write!(Path.join([out, "lib", app, "ebin", "Elixir.#{name}.beam"]), out_bin)
end
# An Erlang module of the app: not an Elixir module, never read.
File.write!(Path.join([out, "lib", "elixir", "ebin", "elixir_aliases.beam"]), "not a beam")
