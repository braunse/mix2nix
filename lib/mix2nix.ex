defmodule Mix2nix do
  require Logger

  defmodule LockfileError do
    defexception [:message]
  end

  defmodule State do
    defstruct fetchers: MapSet.new(), entries: [], errors: []

    def add(%State{errors: []} = state, {:ok, fetcher, entry}) do
      %State{
        state
        | fetchers: MapSet.put(state.fetchers, fetcher),
          entries: [entry | state.entries]
      }
    end

    def add(%State{} = state, {:error, error}) do
      %State{state | errors: [error | state.errors]}
    end

    def format(%State{errors: []} = _without_errors = state) do
      args =
        state.fetchers
        |> Stream.intersperse(", ")
        |> Enum.into([])

      head = ["{ ", args, " }: {\n"]

      entries = state.entries |> Stream.flat_map(&[&1, "\n"]) |> Enum.into([])

      foot = "}\n"

      {:ok, [head, entries, foot]}
    end

    def format(%State{} = _with_errors = state) do
      formatted = state.errors |> Stream.map(&[&1, "\n"]) |> Enum.into([])
      {:error, formatted}
    end
  end

  def read_lockfile(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(bytes, warn_on_unnecessary_quotes: false),
         {%{} = locks, _bindings} <- Code.eval_quoted(quoted, [], file: path) do
      locks
    else
      {:error, posix} when is_atom(posix) ->
        raise LockfileError, message: to_string(:file.format_error(posix))

      {:error, {line, error, token}} when is_integer(line) ->
        raise LockfileError, message: "Error on line #{line}: #{error} (#{inspect(token)})"
    end
  end

  def main(args \\ []) do
    case Mix2nix.Options.from_args(args) do
      {:error, e} ->
        IO.puts("Error parsing command line arguments: #{e}")
        raise R

      :help ->
        IO.puts(Mix2nix.Options.help())

      {:ok, opts} ->
        run(opts)
    end
  end

  def run(opts = %Mix2nix.Options{}) do
    locks = read_lockfile(opts.lockfile)

    exe_path = :escript.script_name() |> Path.expand() |> Path.dirname()
    install_path = Path.dirname(exe_path)
    lib_source = Path.join([install_path, "share", "mix2nix-build.nix"])

    entries =
      locks
      |> Enum.reduce(%State{}, fn {package, lock}, state ->
        state |> State.add(write_lock_entry(package, lock))
      end)

    case State.format(entries) do
      {:ok, entries} ->
        if opts.write_lib do
          File.copy!(lib_source, opts.libfile)
        end

        libfile_relpath = Path.relative_to(opts.libfile, opts.pkgdir)
        depfile_relpath = Path.relative_to(opts.depfile, opts.pkgdir)

        if opts.write_deps do
          File.write!(opts.depfile, entries)
        end

        if opts.write_pkg do
          File.write!(opts.pkgfile, """
          { pkgs ? import <nixpkgs> {}, callPackage ? pkgs.callPackage, ... }@args:
          let
            mix2nix-build = callPackage (./. + "/#{libfile_relpath}") {};
            mixDeps = callPackage (./. + "/#{depfile_relpath}") {};
            unusedArgs = builtins.removeAttrs args ["pkgs" "callPackage"];
          in
            mix2nix-build ({
              name = "#{opts.name}";
              version = "#{opts.version}";
              src = #{opts.src};
              inherit mixDeps;
            } // unusedArgs)
          """)
        end

      {:error, errors} ->
        IO.puts(:stderr, errors)
        System.stop(1)
    end
  end

  defp write_lock_entry(
         package,
         {:hex, package, version, _inner_cksum, _managers, _deps, "hexpm",
          outer_cksum = <<_::binary-size(64)>>}
       ) do
    package = Atom.to_string(package)

    {:ok, "fetchHex",
     """
       hex."#{package}" = fetchHex {
         pkg = "#{package}";
         version = "#{version}";
         sha256 = "#{outer_cksum}";
       };
     """}
  end

  defp write_lock_entry(package, unparseable_lock) do
    {:error,
     "Could not parse lock entry for package #{Atom.to_string(package)}: #{
       inspect(unparseable_lock)
     }"}
  end
end
