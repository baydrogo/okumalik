// Hands pages to the Okumalık app through its okumalik:// address scheme.

function okumalikLink(kind, url, title, tags) {
  let link = `okumalik://${kind}?url=${encodeURIComponent(url)}`;
  if (title) link += `&title=${encodeURIComponent(title)}`;
  if (tags && tags.length) link += `&tags=${encodeURIComponent(tags.join(","))}`;
  return link;
}

async function send({ kind, url, title, tags, tabId }) {
  const link = okumalikLink(kind, url, title, tags);
  try {
    // Opening the link from inside the page keeps the page as it is.
    await browser.tabs.executeScript(tabId, { code: `void (location.href = ${JSON.stringify(link)});` });
  } catch (e) {
    // Pages scripts can't run in (e.g. about: pages).
    await browser.tabs.update(tabId, { url: link });
  }
  browser.browserAction.setBadgeBackgroundColor({ color: "#B04833", tabId });
  browser.browserAction.setBadgeText({ text: "✓", tabId });
  setTimeout(() => browser.browserAction.setBadgeText({ text: "", tabId }), 2000);
}

browser.runtime.onMessage.addListener((message) => {
  if (message && message.type === "send") return send(message);
});

browser.menus.create({ id: "readLater", title: "Okumalık'a Sonra Oku olarak gönder", contexts: ["page", "link"] });
browser.menus.create({ id: "bookmark", title: "Okumalık'a yer imi olarak gönder", contexts: ["page", "link"] });

browser.menus.onClicked.addListener((info, tab) => {
  const kind = info.menuItemId === "bookmark" ? "bookmark" : "add";
  const url = info.linkUrl || tab.url;
  const title = info.linkUrl ? (info.linkText || "").trim() : tab.title;
  if (!/^https?:/.test(url)) return;
  send({ kind, url, title, tags: [], tabId: tab.id });
});
