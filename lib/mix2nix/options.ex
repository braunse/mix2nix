defmodule Mix2nix.Options do
  alias Mix2nix.Utils

  @switches [
    strict: [
      help: :boolean,
      lockfile: :string,
      libfile: :string,
      pkgfile: :string,
      depfile: :string,
      name: :string,
      version: :string,
      src: :string,
      write_lib: :boolean,
      write_pkg: :boolean,
      write_dep: :boolean,
      yarn_assets: :boolean
    ],
    aliases: [
      i: :lockfile,
      o: :pkgfile,
      l: :libfile,
      n: :name,
      v: :version,
      s: :src,
      d: :depfile,
      y: :yarn_assets,
      "H": :help
    ]
  ]

  def help,
    do: """
      #{:escript.script_name |> Path.basename()} <options>

      Options:
        --help, -h            Show this help text
        --lockfile, -i FILE   Mix lock file to parse for dependency information
                              (default: mix.lock)
        --pkgfile, -o FILE    Output file for the package derivation
                              (default: <name>.nix)
        --libfile, -l FILE    Output file for mix2nix build script
                              (default: mix2nix-build.nix)
        --depfile, -d FILE    Output file for dependency information
                              (default: <name>-deps.nix)
        --name, -n NAME       Name of the package (default: ask mix about it)
        --version, -v VER     Version of the package (default: ask mix about it)
        --src, -s SRC         Source for the package (default: ./.)
        --no-write-lib        Do not copy the mix2nix build script file
        --no-write-pkg        Do not write the package driver script file
        --no-write-dep        Do not write the dependency information file
        --yarn-assets         Add code to initialize yarn in the assets subfolder
                              for Phoenix applications with frontend code
    """

  defstruct [
    :lockfile,
    :pkgfile,
    :libfile,
    :name,
    :version,
    :src,
    :depfile,
    :yarn,
    :write_lib,
    :write_pkg,
    :write_deps,
    pkgdir: nil
  ]

  def from_args(args) do
    {switches, args, errors} = IO.inspect(OptionParser.parse(args, @switches))

    from_parsed(switches, args, errors)
    |> validate()
  end

  defp resolve_auto(opts = %__MODULE__{}, sym, fallback) do
    case Map.fetch!(opts, sym) do
      :auto -> %{opts | sym => eval_fallback(opts, fallback)}
      _ -> opts
    end
  end

  defp eval_fallback(_opts, fallback) when is_function(fallback, 0), do: fallback.()
  defp eval_fallback(opts, fallback) when is_function(fallback, 1), do: fallback.(opts)
  defp eval_fallback(_opts, fallback_value), do: fallback_value

  defp from_parsed(_switches, non_empty_args = [_ | _], _errors) do
    {:error, "This command does not accept these arguments: #{Enum.join(non_empty_args, " ")}"}
  end

  defp from_parsed(_switches, [], non_empty_errors = [_ | _]) do
    {:error, "Error in command line: #{inspect(non_empty_errors)}"}
  end

  defp from_parsed(switches, [], []) do
    need_help = switches[:help]

    if need_help do
      :help
    else
      it =
        %__MODULE__{
          lockfile: Keyword.get(switches, :lockfile, "mix.lock") |> Path.expand(),
          pkgfile: Keyword.get(switches, :pkgfile, :auto),
          libfile: Keyword.get(switches, :libfile, :auto),
          name: Keyword.get(switches, :name, :auto),
          version: Keyword.get(switches, :version, :auto),
          src: Keyword.get(switches, :src, "./."),
          depfile: Keyword.get(switches, :depfile, :auto),
          yarn: Keyword.get(switches, :yarn, false),
          write_lib: Keyword.get(switches, :write_lib, true),
          write_pkg: Keyword.get(switches, :write_pkg, true),
          write_deps: Keyword.get(switches, :write_deps, true)
        }
        |> resolve_pkgdir()
        |> resolve_auto(:name, fn opts ->
          Utils.mix_eval(opts.pkgdir, "Mix.Project.config()[:app]")
        end)
        |> resolve_auto(:version, fn opts ->
          Utils.mix_eval(opts.pkgdir, "Mix.Project.config()[:version]")
        end)
        |> resolve_auto(:pkgfile, fn opts ->
          Path.join(opts.pkgdir, "#{opts.name}.nix") |> Path.expand()
        end)
        |> resolve_auto(:libfile, fn opts ->
          Path.join(opts.pkgdir, "mix2nix-build.nix") |> Path.expand()
        end)
        |> resolve_auto(:depfile, fn opts ->
          Path.join(opts.pkgdir, "#{opts.name}-deps.nix") |> Path.expand()
        end)

      {:ok, it}
    end
  end

  defp resolve_pkgdir(opts = %__MODULE__{lockfile: lockfile}) do
    %{opts | pkgdir: Path.dirname(lockfile)}
  end

  defp validate(:help), do: :help
  defp validate(e = {:error, _}), do: e

  defp validate({:ok, opts}) do
    with :ok <- validate(File.exists?(opts.lockfile), "Lockfile does not exist: #{opts.lockfile}") do
      {:ok, opts}
    else
      e = {:error, _} -> e
    end
  end

  defp validate(positive, _message) when positive in [:ok, true], do: :ok
  defp validate(false, message), do: {:error, message}
  defp validate(e = {:error, _}, message) when is_function(message), do: {:error, message.(e)}
  defp validate(e = {:error, _}, message), do: {:error, message}
end
