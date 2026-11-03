const $ = (id) => document.getElementById(id);

function parseTags(text) {
  return [...new Set(text.split(",").map((t) => t.trim().replace(/^#/, "").toLocaleLowerCase("tr")).filter(Boolean))];
}

async function main() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  const { recentTags = [] } = await browser.storage.local.get("recentTags");
  const web = tab && /^https?:/.test(tab.url || "");

  $("title").value = (tab && tab.title) || "";
  $("host").textContent = web ? new URL(tab.url).hostname.replace(/^www\./, "") : "";

  const renderChips = () => {
    const current = parseTags($("tags").value);
    $("recent").replaceChildren(...recentTags.slice(0, 12).map((tag) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip" + (current.includes(tag) ? " on" : "");
      chip.textContent = "#" + tag;
      chip.addEventListener("click", () => {
        const tags = parseTags($("tags").value);
        const next = tags.includes(tag) ? tags.filter((t) => t !== tag) : [...tags, tag];
        $("tags").value = next.join(", ");
        renderChips();
      });
      return chip;
    }));
  };
  $("tags").addEventListener("input", renderChips);
  renderChips();

  if (!web) {
    $("note").hidden = false;
    $("note").textContent = "Bu sayfa gönderilemez; yalnızca web sayfaları gönderilebilir.";
    $("readLater").disabled = $("bookmark").disabled = true;
    return;
  }

  const submit = async (kind) => {
    const tags = parseTags($("tags").value);
    $("readLater").disabled = $("bookmark").disabled = true;
    await browser.storage.local.set({ recentTags: [...new Set([...tags, ...recentTags])].slice(0, 30) });
    await browser.runtime.sendMessage({ type: "send", kind, url: tab.url, title: $("title").value.trim(), tags, tabId: tab.id });
    window.close();
  };
  $("readLater").addEventListener("click", () => submit("add"));
  $("bookmark").addEventListener("click", () => submit("bookmark"));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit("add"); }
  });
  $("tags").focus();
}

main();
