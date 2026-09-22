import { assertEquals } from "@std/assert"
import { dedupe, extract, guess } from "./links.ts"

const osc8 = (target: string, label: string) =>
  `\x1b]8;;${target}\x1b\\${label}\x1b]8;;\x1b\\`

Deno.test("hyperlink keeps its label", () => {
  const line = `see ${osc8("https://example.com/deep", "the docs")} now`
  assertEquals(extract(line), [{
    label: "the docs",
    target: "https://example.com/deep",
    kind: "url",
  }])
})

Deno.test("hyperlink label survives colour codes", () => {
  const line = osc8("https://example.com", "\x1b[32mgreen\x1b[0m")
  assertEquals(extract(line)[0].label, "green")
})

Deno.test("bare url is its own label", () => {
  assertEquals(extract("go to https://example.com/x."), [{
    label: "https://example.com/x",
    target: "https://example.com/x",
    kind: "url",
  }])
})

Deno.test("hyperlink target is not repeated as a bare url", () => {
  assertEquals(extract(osc8("https://example.com", "label")).length, 1)
})

Deno.test("paths are found", () => {
  assertEquals(
    extract("edit ~/dotfiles/.tmux.conf please").map((link) => link.target),
    ["~/dotfiles/.tmux.conf"],
  )
})

Deno.test("a file:// hyperlink and a bare path are one entry", () => {
  const links = [
    ...extract(osc8("file:///home/u/dev/x.ts", "x.ts")),
    ...extract("see ~/dev/x.ts"),
  ]
  assertEquals(dedupe(links, "/home/u").length, 1)
})

Deno.test("the labelled entry wins a duplicate", () => {
  const links = [
    ...extract("see https://example.com"),
    ...extract(osc8("https://example.com", "the docs")),
  ]
  assertEquals(dedupe(links, "/home/u")[0].label, "the docs")
})

Deno.test("icons come from the extension", () => {
  assertEquals(guess("/a/b.png"), "image")
  assertEquals(guess("/a/b.tar.zst"), "other")
  assertEquals(guess("/a/b.ts"), "text")
  assertEquals(guess("/a/README"), "text")
  assertEquals(guess("/a/.tmux.conf"), "text")
})
