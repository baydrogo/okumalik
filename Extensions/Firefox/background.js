// Hands pages and pictures to the Okumalık app through its okumalik:// address scheme.

function okumalikLink(kind, url, title, tags) {
  let link = `okumalik://${kind}?url=${encodeURIComponent(url)}`;
  if (title) link += `&title=${encodeURIComponent(title)}`;
  if (tags && tags.length) link += `&tags=${encodeURIComponent(tags.join(","))}`;
  return link;
}

async function openLink(link, tabId) {
  try {
    // Opening the link from inside the page keeps the page as it is.
    await browser.tabs.executeScript(tabId, { code: `void (location.href = ${JSON.stringify(link)});` });
  } catch (e) {
    // Pages scripts can't run in (e.g. about: pages).
    await browser.tabs.update(tabId, { url: link });
  }
  browser.browserAction.setBadgeBackgroundColor({ color: "#2F6BD8", tabId });
  browser.browserAction.setBadgeText({ text: "✓", tabId });
  setTimeout(() => browser.browserAction.setBadgeText({ text: "", tabId }), 2000);
}

async function send({ kind, url, title, tags, tabId }) {
  await openLink(okumalikLink(kind, url, title, tags), tabId);
}

// Pictures go by address; Okumalık downloads them itself, with the page as referrer.
// Pictures that only live in the page (blob:) are turned into data: addresses there first.
async function sendImage(src, tab) {
  if (src.startsWith("blob:")) {
    try {
      const [data] = await browser.tabs.executeScript(tab.id, {
        code: `fetch(${JSON.stringify(src)}).then((r) => r.blob()).then((b) => new Promise((done) => {
          const reader = new FileReader(); reader.onload = () => done(reader.result); reader.readAsDataURL(b);
        }))`,
      });
      src = data;
    } catch (e) {
      return;
    }
  }
  if (!/^(https?:|data:image\/)/.test(src || "")) return;
  // Very long data: addresses don't survive being handed to the app.
  if (src.startsWith("data:") && src.length > 1500000) return;
  let link = `okumalik://image?src=${encodeURIComponent(src)}`;
  if (/^https?:/.test(tab.url || "")) link += `&page=${encodeURIComponent(tab.url)}`;
  if (tab.title) link += `&title=${encodeURIComponent(tab.title)}`;
  await openLink(link, tab.id);
}

browser.runtime.onMessage.addListener((message) => {
  if (message && message.type === "send") return send(message);
});

browser.menus.create({ id: "readLater", title: "Okumalık'a Sonra Oku olarak gönder", contexts: ["page", "link"] });
browser.menus.create({ id: "bookmark", title: "Okumalık'a yer imi olarak gönder", contexts: ["page", "link"] });
browser.menus.create({ id: "image", title: "Görseli Okumalık'a gönder", contexts: ["image"] });

browser.menus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "image") return sendImage(info.srcUrl || "", tab);
  const kind = info.menuItemId === "bookmark" ? "bookmark" : "add";
  const url = info.linkUrl || tab.url;
  const title = info.linkUrl ? (info.linkText || "").trim() : tab.title;
  if (!/^https?:/.test(url)) return;
  send({ kind, url, title, tags: [], tabId: tab.id });
});
