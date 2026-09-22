#!/usr/bin/env -S deno run --allow-run --allow-read --allow-env

import {
  dedupe,
  expand,
  extract,
  guess,
  type Kind,
  type Link,
} from "./links.ts"

const HISTORY_LIMIT = 2000
const LABEL_MAX = 50
const DIM = "\x1b[2m"
const RESET = "\x1b[0m"

type Entry = {
  readonly label: string
  readonly target: string
  readonly kind: Kind
}

const ICON: Record<Kind, string> = {
  url: "🌐",
  text: "📄",
  image: "🖼️",
  dir: "📁",
  other: "📎",
}

const NOISE = [
  /claude[.]ai\/code\/session_/,
]

const wanted = (link: Link) =>
  !NOISE.some((pattern) => pattern.test(link.target))

const home = () => Deno.env.get("HOME") ?? ""

const sh = async (cmd: string, args: string[]) => {
  const { stdout } = await new Deno.Command(cmd, {
    args,
    stdout: "piped",
    stderr: "null",
  }).output()
  return new TextDecoder().decode(stdout)
}

const capture = (pane: string) =>
  sh("tmux", [
    "capture-pane",
    "-p",
    "-e",
    "-J",
    "-t",
    pane,
    "-S",
    `-${HISTORY_LIMIT}`,
  ])

const mine = (link: Link) =>
  link.target.startsWith(".") || expand(link.target, home()).startsWith(home())

const classify = async (link: Link): Promise<Kind | undefined> => {
  if (link.kind === "url") return "url"
  if (!mine(link)) return undefined
  const path = expand(link.target, home())
  const stat = await Deno.stat(path).catch(() => undefined)
  return stat === undefined ? undefined : stat.isDirectory ? "dir" : guess(path)
}

const entries = async (links: readonly Link[]): Promise<readonly Entry[]> => {
  const kinds = await Promise.all(links.map(classify))
  return links
    .map((link, i) => ({ ...link, kind: kinds[i] }))
    .filter((entry): entry is Entry => entry.kind !== undefined)
}

const named = (entry: Entry) =>
  expand(entry.label, home()) === expand(entry.target, home())
    ? ""
    : entry.label

const column = (entries: readonly Entry[]) =>
  Math.min(
    LABEL_MAX,
    entries.reduce((width, entry) => Math.max(width, named(entry).length), 0),
  )

const row = (entry: Entry, width: number) => {
  const name = named(entry)
  const label = name.length > width
    ? `${name.slice(0, width - 1)}…`
    : name.padEnd(width)
  const shown = `${label}  ${ICON[entry.kind]}  ${DIM}${entry.target}${RESET}`
  return `${shown}\t${entry.target}\t${entry.kind}`
}

const pick = async (entries: readonly Entry[]) => {
  const width = column(entries)
  const input = entries.map((entry) => row(entry, width)).join("\n")
  const fzf = new Deno.Command("fzf", {
    args: [
      "--tmux",
      "center,90%,60%",
      "--ansi",
      "--delimiter",
      "\t",
      "--with-nth",
      "1",
      "--no-sort",
      "--no-preview",
      "-0",
      "-1",
    ],
    stdin: "piped",
    stdout: "piped",
    stderr: "inherit",
  }).spawn()
  const writer = fzf.stdin.getWriter()
  await writer.write(new TextEncoder().encode(input))
  await writer.close()
  const { stdout } = await fzf.output()
  return new TextDecoder().decode(stdout).trim()
}

const edit = (path: string) =>
  sh("tmux", ["new-window", "--", Deno.env.get("EDITOR") ?? "vi", path])

const isText = async (path: string) =>
  (await sh("xdg-mime", ["query", "filetype", path])).startsWith("text/")

const openEntry = async (entry: Entry) => {
  if (entry.kind === "url") return sh("xdg-open", [entry.target])
  const path = expand(entry.target, home())
  if (entry.kind === "dir") return edit(path)
  return await isText(path) ? edit(path) : sh("xdg-open", [path])
}

const notify = (message: string) => sh("tmux", ["display-message", message])

const main = async () => {
  const raw = await capture(Deno.args[0] ?? "")
  const found = dedupe(
    raw.split("\n").reverse().flatMap((line) => extract(line)),
    home(),
  )
  const listed = await entries(found.filter(wanted))

  if (listed.length === 0) return notify("tmux-links: nothing found")

  const chosen = await pick(listed)
  if (chosen === "") return

  const [, target, kind] = chosen.split("\t")
  await openEntry({ label: target, target, kind: kind as Kind })
}

await main()
