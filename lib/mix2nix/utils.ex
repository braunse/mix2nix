defmodule Mix2nix.Utils do
  def ensure_successful_cmd({retval, 0}, _cmd), do: retval

  def ensure_successful_cmd({_, _failed}, cmd),
    do: raise(RuntimeError, message: "The command #{cmd} failed")

  def mix_eval(pkgdir, expr) do
    System.cmd(
      "mix",
      [
        "run",
        "--no-compile",
        "--no-deps-check",
        "--no-start",
        "-e",
        "IO.write(#{expr})"
      ],
      cd: pkgdir
    )
    |> ensure_successful_cmd("mix run (get app version)")
    |> String.trim()
end
end
