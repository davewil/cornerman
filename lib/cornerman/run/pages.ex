defmodule Cornerman.Run.Pages do
  @moduledoc """
  The results pages: the live status page, the final report, the library's live and
  version pages, the runs index, and the `view/<run_id>/<task>--<file>.html` wrappers that
  show a worker log, a text deliverable or a task report in the browser.

  Which files exist, and where, follows Ringer exactly, because links printed at the end of
  a run and stored in `library.json` must resolve. The markup is a plain interim page
  (DIVERGENCES.toml: `run/*` `**/*.html`); phase 3 renders these from HEEx components.

  Wrapper rules (Ringer's `render_task_links` and `work_item_href`), for each task a page
  shows: the first of `report.md` / `report.html` that exists (wrapped unless it is HTML),
  the worker log if it exists, and every harvested deliverable with a `.md`, `.txt` or
  `.log` suffix that exists. The live page shows finished tasks only; the final report
  shows all.
  """

  alias Cornerman.Py
  alias Cornerman.Run.{Artifacts, Files, Spec}

  @report_names ["report.md", "report.html"]
  @text_suffixes [".md", ".txt", ".log"]
  @wrapper_tail_bytes 256 * 1024

  @typedoc "Source files already wrapped: `wrapper path => {mtime, size}` of the source."
  @type cache :: %{String.t() => {integer(), integer()}}

  @doc "The status page and the library's live page, from a state snapshot."
  @spec write_status(map(), Spec.t(), cache()) :: cache()
  def write_status(state, %Spec{} = spec, cache) do
    finished? = state["finished"] == true or state["state"] == "finished"

    Enum.reduce([spec.artifact_path, spec.live_path], cache, fn page, cache ->
      {html, cache} = page(state, spec, page, finished?, finished?, cache)
      Files.atomic_write(page, html)
      cache
    end)
  end

  @doc "The final report and the library's version page."
  @spec write_final(map(), Spec.t(), cache()) :: cache()
  def write_final(state, %Spec{} = spec, cache) do
    Enum.reduce([spec.report_path, spec.version_path], cache, fn page, cache ->
      {html, cache} = page(state, spec, page, true, true, cache)
      Files.atomic_write(page, html)
      cache
    end)
  end

  defp page(state, spec, page_path, final?, force?, cache) do
    tasks =
      if final?,
        do: state["tasks"],
        else: Enum.filter(state["tasks"], &(bucket(&1["status"]) in ["pass", "fail"]))

    {rows, cache} =
      Enum.map_reduce(tasks, cache, fn task, cache ->
        {links, cache} = task_links(task, state, spec, page_path, force?, cache)
        {task_row(task, links), cache}
      end)

    title = if final?, do: "ringer report", else: "ringer"

    body = [
      "<h1>",
      esc(state["run_name"]),
      "</h1>\n<p>Run <code>",
      esc(state["run_id"]),
      "</code> by ",
      esc(state["identity"]),
      ": ",
      esc(state["state"]),
      ", #{state["totals"]["pass"]} passed, #{state["totals"]["fail"]} failed.</p>\n",
      if(rows == [],
        do: "<p>Deliverables appear here as workers finish.</p>\n",
        else: [
          "<table>\n<thead><tr><th>task</th><th>status</th><th>verdict</th><th>attempts</th>",
          "<th>what the check proves</th><th>work</th></tr></thead>\n<tbody>\n",
          rows,
          "</tbody>\n</table>\n"
        ]
      )
    ]

    refresh = if final?, do: "", else: ~s(<meta http-equiv="refresh" content="2">\n)
    {document("#{title} · #{state["run_name"]}", refresh, body), cache}
  end

  defp task_row(task, links) do
    [
      "<tr><td>",
      esc(task["key"]),
      "</td><td>",
      esc(task["status"]),
      "</td><td>",
      esc(task["verdict"] || ""),
      "</td><td>",
      Integer.to_string(task["attempts"]),
      "</td><td>",
      esc(task["verified"] || ""),
      "</td><td>",
      if(links == [], do: "—", else: Enum.intersperse(links, " · ")),
      "</td></tr>\n"
    ]
  end

  defp task_links(task, state, spec, page_path, force?, cache) do
    key = task["key"]
    run_id = state["run_id"]
    artifact_dir = Path.dirname(spec.artifact_path)

    {deliverables, cache} =
      Enum.map_reduce(task["deliverables"], cache, fn item, cache ->
        source = item["path"]

        if text_file?(source) and File.exists?(source) do
          wrapper = wrapper_path(artifact_dir, run_id, key, Path.basename(source))
          cache = write_wrapper(source, wrapper, state["run_name"], key, force?, cache)
          {link(wrapper, page_path, item["name"]), cache}
        else
          {link(source, page_path, item["name"]), cache}
        end
      end)

    {report, cache} =
      case report_file(task) do
        nil ->
          {[], cache}

        source ->
          if html?(source) do
            {[link(source, page_path, "what it found")], cache}
          else
            wrapper = wrapper_path(artifact_dir, run_id, key, Path.basename(source))
            cache = write_wrapper(source, wrapper, state["run_name"], key, force?, cache)
            {[link(wrapper, page_path, "what it found")], cache}
          end
      end

    {log, cache} =
      if File.exists?(task["log_path"]) do
        wrapper = wrapper_path(artifact_dir, run_id, key, Path.basename(task["log_path"]))
        cache = write_wrapper(task["log_path"], wrapper, state["run_name"], key, force?, cache)
        {[link(wrapper, page_path, "work log")], cache}
      else
        {[], cache}
      end

    {deliverables ++ report ++ log, cache}
  end

  defp report_file(task) do
    Enum.find_value(@report_names, fn name ->
      path = Map.get(task["report_paths"], name) || Path.join(task["taskdir"], name)
      if File.exists?(path), do: path
    end)
  end

  @doc "The runs index across every run state under the state dir."
  @spec write_index(Spec.t(), cache()) :: cache()
  def write_index(%Spec{} = spec, cache) do
    index = spec.config.artifact.index_out
    artifact_dir = Path.dirname(spec.artifact_path)

    {rows, cache} =
      spec.config.state_dir
      |> Artifacts.scan_run_states()
      |> Enum.map_reduce(cache, fn entry, cache ->
        {report, cache} = index_report_link(entry, artifact_dir, index, cache)

        live =
          if entry["artifact_path"], do: [link(entry["artifact_path"], index, "live")], else: []

        links = live ++ report

        row = [
          "<tr><td>",
          esc(Py.str(Map.get(entry, "state", "live"))),
          "</td><td>",
          esc(Py.str(Map.get(entry, "run_name", "ringer"))),
          "</td><td>",
          esc(Py.str(Map.get(entry, "identity", "unknown"))),
          "</td><td>",
          esc(
            "#{Py.str(Map.get(entry, "pass", 0))} pass / #{Py.str(Map.get(entry, "fail", 0))} fail"
          ),
          "</td><td>",
          if(links == [], do: "—", else: Enum.intersperse(links, " · ")),
          "</td></tr>\n"
        ]

        {row, cache}
      end)

    body = [
      "<h1>Ringer runs</h1>\n<table>\n<thead><tr><th>state</th><th>run</th><th>identity</th>",
      "<th>tasks</th><th>pages</th></tr></thead>\n<tbody>\n",
      if(rows == [], do: "<tr><td colspan=\"5\">no runs recorded yet</td></tr>\n", else: rows),
      "</tbody>\n</table>\n"
    ]

    Files.atomic_write(index, document("ringer runs", "", body))
    cache
  end

  # Ringer's link_for_source with task key "run": HTML is linked as is, anything else that
  # exists gets a wrapper.
  defp index_report_link(entry, artifact_dir, index, cache) do
    report = if entry["report_ready"], do: entry["report_path"]
    report = if Py.truthy?(report), do: Py.str(report), else: nil

    cond do
      report == nil ->
        {[], cache}

      html?(report) or not File.exists?(report) ->
        {[link(report, index, "report")], cache}

      true ->
        run_id = Py.str(entry["run_id"] || "run")
        wrapper = wrapper_path(artifact_dir, run_id, "run", Path.basename(report))

        cache =
          write_wrapper(
            report,
            wrapper,
            Py.str(entry["run_name"] || "ringer"),
            "run",
            false,
            cache
          )

        {[link(wrapper, index, "report")], cache}
    end
  end

  @doc "`<artifact dir>/view/<run id>/<task>--<file>.html`."
  @spec wrapper_path(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def wrapper_path(artifact_dir, run_id, task_key, source_name) do
    name = "#{Artifacts.sanitize(task_key)}--#{Artifacts.sanitize(source_name)}.html"
    Path.join([artifact_dir, "view", Artifacts.sanitize(run_id), name])
  end

  # Rewritten only when the source changed since the last write (or when forced).
  defp write_wrapper(source, wrapper, run_name, task_key, force?, cache) do
    case File.stat(source, time: :posix) do
      {:ok, stat} ->
        current = {stat.mtime, stat.size}

        if not force? and File.exists?(wrapper) and Map.get(cache, wrapper) == current do
          cache
        else
          Files.atomic_write(wrapper, wrapper_html(source, stat.size, run_name, task_key))
          Map.put(cache, wrapper, current)
        end

      {:error, _} ->
        cache
    end
  end

  defp wrapper_html(source, size, run_name, task_key) do
    start = max(0, size - @wrapper_tail_bytes)

    content =
      case File.open(source, [:read, :binary, :raw]) do
        {:ok, fd} ->
          try do
            {:ok, _} = :file.position(fd, start)

            case :file.read(fd, size - start) do
              {:ok, bytes} -> bytes
              _ -> ""
            end
          after
            File.close(fd)
          end

        {:error, _} ->
          ""
      end

    note =
      if start > 0, do: " Showing the last #{@wrapper_tail_bytes} bytes of #{size}.", else: ""

    document(Path.basename(source), "", [
      "<h1>",
      esc(Path.basename(source)),
      "</h1>\n<p>",
      esc(run_name),
      " · ",
      esc(task_key),
      ".",
      note,
      "</p>\n<pre>",
      esc(Py.decode_replace(content)),
      "</pre>\n"
    ])
  end

  defp document(title, head_extra, body) do
    [
      "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>",
      esc(title),
      "</title>\n",
      head_extra,
      "</head>\n<body>\n",
      body,
      "</body>\n</html>\n"
    ]
  end

  defp link(target, page_path, label) do
    href = Path.relative_to(target, Path.dirname(page_path), force: true)
    [~s(<a href="), esc(href), ~s(">), esc(label), "</a>"]
  end

  defp text_file?(path), do: String.downcase(Py.suffix(path)) in @text_suffixes
  defp html?(path), do: String.downcase(Py.suffix(path)) in [".html", ".htm"]

  defp bucket("pass"), do: "pass"
  defp bucket(status) when status in ["fail", "error", "timeout", "died"], do: "fail"
  defp bucket(_), do: "other"

  defp esc(nil), do: ""

  defp esc(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#x27;")
  end

  defp esc(other), do: esc(Py.str(other))
end
