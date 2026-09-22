const OSC8 =
  /\x1b\]8;[^;]*;([^\x1b\x07]*)(?:\x1b\\|\x07)([\s\S]*?)\x1b\]8;[^;]*;(?:\x1b\\|\x07)/g
const ANSI =
  /\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x1b\x07]*(?:\x1b\\|\x07)|\x1b[()][AB0]/g
const URL = /(?:https?|ftp|file):\/\/[^\s'"<>()\[\]`]+/g
const PATH = /(?:~|\.{1,2})?\/[\w@.+\-\/]*[\w@+\-]/g
const TRAILING = /[.,:;!?)\]}'"]+$/

export type Link = {
  readonly label: string
  readonly target: string
  readonly kind: "url" | "file"
}

export const strip = (text: string) => text.replace(ANSI, "")

export const expand = (path: string, home: string) =>
  path.startsWith("~/") ? `${home}${path.slice(1)}` : path

const asLink = (target: string, label: string): Link =>
  target.startsWith("file://")
    ? { label, target: decodeURIComponent(target.slice(7)), kind: "file" }
    : target.startsWith("/") || target.startsWith("~") || target.startsWith(".")
    ? { label, target, kind: "file" }
    : { label, target, kind: "url" }

export const identity = (link: Link, home: string) =>
  link.kind === "file" ? expand(link.target, home) : link.target

const hyperlinks = (raw: string): readonly Link[] =>
  [...raw.matchAll(OSC8)].map(([, target, label]) =>
    asLink(target, strip(label).trim())
  )

const matches = (text: string, pattern: RegExp) =>
  [...text.matchAll(pattern)]
    .map(([match]) => match.replace(TRAILING, ""))
    .map((target) => asLink(target, target))

export const extract = (raw: string): readonly Link[] => {
  const text = strip(raw)
  return [
    ...hyperlinks(raw),
    ...matches(text, URL),
    ...matches(text.replace(URL, " "), PATH),
  ]
}

const richer = (a: Link, b: Link) => (a.label === a.target ? b : a)

export const dedupe = (links: readonly Link[], home: string) => {
  const seen = new Map<string, Link>()
  links.forEach((link) => {
    const key = identity(link, home)
    const kept = seen.get(key)
    seen.set(key, kept === undefined ? link : richer(kept, link))
  })
  return [...seen.values()]
}

export type Kind = "url" | "text" | "image" | "dir" | "other"

const IMAGE = new Set([
  "png",
  "jpg",
  "jpeg",
  "gif",
  "webp",
  "svg",
  "bmp",
  "ico",
  "avif",
  "heic",
  "tif",
  "tiff",
])

const BINARY = new Set([
  "pdf",
  "zip",
  "gz",
  "xz",
  "zst",
  "tar",
  "7z",
  "mp3",
  "mp4",
  "mkv",
  "wav",
  "ogg",
  "webm",
  "docx",
  "xlsx",
  "pptx",
  "odt",
  "epub",
  "ttf",
  "otf",
  "woff",
  "woff2",
  "so",
  "bin",
  "exe",
  "wasm",
])

const extension = (path: string) => {
  const name = path.slice(path.lastIndexOf("/") + 1)
  const dot = name.lastIndexOf(".")
  return dot <= 0 ? "" : name.slice(dot + 1).toLowerCase()
}

export const guess = (path: string): Kind => {
  const ext = extension(path)
  return IMAGE.has(ext) ? "image" : BINARY.has(ext) ? "other" : "text"
}
