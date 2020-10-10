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

  @switches [
    strict: [
      lockfile: :string,
      libfile: :string,
      pkgfile: :string,
      depfile: :string,
      name: :string,
      version: :string,
      src: :string,
      no_write_lib: :boolean,
      no_write_pkg: :boolean,
      no_write_dep: :boolean
    ],
    aliases: [i: :lockfile, o: :pkgfile, l: :libfile, n: :name, v: :version, s: :src, d: :depfile]
  ]

  def main(args \\ []) do
    {switches, _args} = OptionParser.parse!(args, @switches)

    lockfile = Keyword.get(switches, :lockfile, "mix.lock") |> Path.expand()
    lockdir = Path.dirname(lockfile)

    IO.puts("Lockfile: #{lockfile}")

    name =
      Keyword.get_lazy(switches, :name, fn ->
        System.cmd(
          "mix",
          [
            "run",
            "--no-compile",
            "--no-deps-check",
            "--no-start",
            "-e",
            "IO.write(Atom.to_string(Mix.Project.config()[:app]))"
          ],
          cd: lockdir
        )
        |> ensure_successful_cmd("mix run (get app name)")
        |> String.trim()
      end)

    version =
      Keyword.get_lazy(switches, :version, fn ->
        System.cmd(
          "mix",
          [
            "run",
            "--no-compile",
            "--no-deps-check",
            "--no-start",
            "-e",
            "IO.write(Mix.Project.config()[:version])"
          ],
          cd: lockdir
        )
        |> ensure_successful_cmd("mix run (get app version)")
        |> String.trim()
      end)

    pkgfile =
      Keyword.get(switches, :pkgfile, Path.join(Path.dirname(lockfile), "#{name}.nix"))
      |> Path.expand()

    pkgdir = Path.dirname(pkgfile)

    depfile =
      Keyword.get(switches, :depfile, Path.join(Path.dirname(pkgfile), "#{name}-deps.nix"))
      |> Path.expand()

    libfile =
      Keyword.get(switches, :libfile, Path.join(Path.dirname(pkgfile), "mix2nix-build.nix"))
      |> Path.expand()

    exe_path = Path.expand(Path.dirname(Path.dirname(:escript.script_name())))
    lib_source = Path.join([exe_path, "share", "mix2nix-build.nix"])
    src = Keyword.get(switches, :src, "./.")

    locks = read_lockfile(lockfile)

    entries =
      locks
      |> Enum.reduce(%State{}, fn {package, lock}, state ->
        state |> State.add(write_lock_entry(package, lock))
      end)

    case State.format(entries) do
      {:ok, entries} ->
        unless Keyword.get(switches, :no_write_lib) do
          File.copy!(lib_source, libfile)
        end

        libfile_relpath = Path.relative_to(libfile, pkgdir)
        depfile_relpath = Path.relative_to(depfile, pkgdir)

        unless Keyword.get(switches, :no_write_dep) do
          File.write!(depfile, entries)
        end

        unless Keyword.get(switches, :no_write_pkg) do
          File.write!(pkgfile, """
          { pkgs ? import <nixpkgs> {}, callPackage ? pkgs.callPackage, ... }@args:
          let
            mix2nix-build = callPackage (./. + "/#{libfile_relpath}") {};
            mixDeps = callPackage (./. + "/#{depfile_relpath}") {};
            unusedArgs = builtins.removeAttrs args ["pkgs" "callPackage"];
          in
            mix2nix-build ({
              name = "#{name}";
              version = "#{version}";
              src = #{src};
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

  defp ensure_successful_cmd({retval, 0}, _cmd), do: retval

  defp ensure_successful_cmd({_, _failed}, cmd),
    do: raise(RuntimeError, message: "The command #{cmd} failed")
end
