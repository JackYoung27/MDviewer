(() => {
  const contentEl = document.getElementById("content");
  const payloadEl = document.getElementById("viewer-data");
  const decoder = new TextDecoder();
  const searchState = {
    query: "",
    matches: [],
    activeIndex: -1,
    panelEl: null,
    inputEl: null,
    countEl: null,
  };
  let renderedContentHtml = "";
  let renderedDocumentTitle = document.title;

  function getMode() {
    return localStorage.getItem("mdv-theme") || "auto";
  }

  function getEffectiveTheme() {
    const mode = getMode();
    if (mode === "dark" || mode === "light") return mode;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function updateToggleButton() {
    const btn = document.querySelector(".theme-toggle");
    if (!btn) return;
    const mode = getMode();
    if (mode === "auto") {
      btn.textContent = "\u25D1";
      btn.setAttribute("aria-label", "Theme: auto (system) \u2014 click to switch to light");
    } else if (mode === "light") {
      btn.textContent = "\u2600";
      btn.setAttribute("aria-label", "Theme: light \u2014 click to switch to dark");
    } else {
      btn.textContent = "\u263E";
      btn.setAttribute("aria-label", "Theme: dark \u2014 click to switch to auto");
    }
  }

  function applyMode(mode) {
    if (mode === "auto") {
      document.documentElement.removeAttribute("data-theme");
      localStorage.removeItem("mdv-theme");
    } else {
      document.documentElement.setAttribute("data-theme", mode);
      localStorage.setItem("mdv-theme", mode);
    }
    updateToggleButton();
  }

  function toggleTheme() {
    const mode = getMode();
    if (mode === "auto") applyMode("light");
    else if (mode === "light") applyMode("dark");
    else applyMode("auto");
  }

  window.toggleTheme = toggleTheme;

  function initTheme() {
    const saved = localStorage.getItem("mdv-theme");
    if (saved === "dark" || saved === "light") {
      document.documentElement.setAttribute("data-theme", saved);
    }

    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (getMode() === "auto") updateToggleButton();
    });
  }

  function createToggleButton() {
    const btn = document.createElement("button");
    btn.className = "theme-toggle";
    btn.addEventListener("click", toggleTheme);
    document.body.appendChild(btn);
    updateToggleButton();
  }

  function updateSearchCountLabel() {
    if (!searchState.countEl) return;

    if (!searchState.query) {
      searchState.countEl.textContent = "";
      return;
    }

    if (searchState.matches.length === 0) {
      searchState.countEl.textContent = "No matches";
      return;
    }

    searchState.countEl.textContent = `${searchState.activeIndex + 1} of ${searchState.matches.length}`;
  }

  function applyRenderedContent() {
    contentEl.innerHTML = renderedContentHtml || "<p></p>";
    disableTaskCheckboxes(contentEl);
    finalizeLinks(contentEl);
    finalizeImages(contentEl);
    document.title = renderedDocumentTitle;
  }

  function clearSearchSelection() {
    for (const match of searchState.matches) {
      match.classList.remove("find-match--active");
    }

    searchState.matches = [];
    searchState.activeIndex = -1;
    updateSearchCountLabel();
  }

  function resetSearchHighlights() {
    clearSearchSelection();
    applyRenderedContent();
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function collectSearchMatches(query) {
    const pattern = new RegExp(escapeRegExp(query), "gi");
    const walker = document.createTreeWalker(
      contentEl,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (!node.nodeValue || !node.nodeValue.trim()) {
            return NodeFilter.FILTER_REJECT;
          }

          const parent = node.parentElement;
          if (!parent) {
            return NodeFilter.FILTER_REJECT;
          }

          if (parent.closest(".find-panel")) {
            return NodeFilter.FILTER_REJECT;
          }

          if (["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) {
            return NodeFilter.FILTER_REJECT;
          }

          return NodeFilter.FILTER_ACCEPT;
        },
      }
    );

    const textNodes = [];
    while (walker.nextNode()) {
      textNodes.push(walker.currentNode);
    }

    const matches = [];

    for (const textNode of textNodes) {
      const text = textNode.nodeValue;
      pattern.lastIndex = 0;

      let match = pattern.exec(text);
      if (!match) continue;

      const fragment = document.createDocumentFragment();
      let lastIndex = 0;

      while (match) {
        const start = match.index;
        const end = start + match[0].length;

        if (start > lastIndex) {
          fragment.appendChild(document.createTextNode(text.slice(lastIndex, start)));
        }

        const mark = document.createElement("mark");
        mark.className = "find-match";
        mark.textContent = text.slice(start, end);
        fragment.appendChild(mark);
        matches.push(mark);

        lastIndex = end;
        match = pattern.exec(text);
      }

      if (lastIndex < text.length) {
        fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
      }

      textNode.parentNode.replaceChild(fragment, textNode);
    }

    return matches;
  }

  function activateSearchMatch(index, shouldScroll = true) {
    if (searchState.matches.length === 0) {
      searchState.activeIndex = -1;
      updateSearchCountLabel();
      return;
    }

    for (const match of searchState.matches) {
      match.classList.remove("find-match--active");
    }

    const normalizedIndex = ((index % searchState.matches.length) + searchState.matches.length) % searchState.matches.length;
    const activeMatch = searchState.matches[normalizedIndex];
    activeMatch.classList.add("find-match--active");
    searchState.activeIndex = normalizedIndex;
    updateSearchCountLabel();

    if (shouldScroll) {
      activeMatch.scrollIntoView({ behavior: "auto", block: "center", inline: "nearest" });
    }
  }

  function updateSearch(query, options = {}) {
    const normalizedQuery = (query || "").trim();
    const preserveIndex = options.preserveIndex === true;
    const previousIndex = searchState.activeIndex;

    searchState.query = normalizedQuery;
    resetSearchHighlights();

    if (!normalizedQuery) {
      return;
    }

    searchState.matches = collectSearchMatches(normalizedQuery);

    if (searchState.matches.length === 0) {
      updateSearchCountLabel();
      return;
    }

    const nextIndex = preserveIndex && previousIndex >= 0 ? previousIndex : 0;
    activateSearchMatch(nextIndex, options.scrollToMatch !== false);
  }

  function jumpToSearchMatch(direction) {
    if (!searchState.query) {
      openFindBar();
      return;
    }

    if (searchState.matches.length === 0) {
      updateSearch(searchState.query, { scrollToMatch: false });
    }

    if (searchState.matches.length === 0) {
      return;
    }

    const baseIndex = searchState.activeIndex >= 0 ? searchState.activeIndex : 0;
    activateSearchMatch(baseIndex + direction);
  }

  function closeFindBar() {
    if (!searchState.panelEl) return;
    searchState.panelEl.classList.remove("find-panel--visible");
    searchState.query = "";
    if (searchState.inputEl) {
      searchState.inputEl.value = "";
    }
    resetSearchHighlights();
  }

  function openFindBar() {
    if (!searchState.panelEl) return;
    searchState.panelEl.classList.add("find-panel--visible");
    searchState.inputEl.focus();
    searchState.inputEl.select();
    updateSearch(searchState.inputEl.value, { scrollToMatch: false });
  }

  function toggleFindBar() {
    if (!searchState.panelEl) return;

    if (searchState.panelEl.classList.contains("find-panel--visible")) {
      closeFindBar();
    } else {
      openFindBar();
    }
  }

  function createSearchPanel() {
    const panel = document.createElement("section");
    panel.className = "find-panel";
    panel.setAttribute("role", "search");
    panel.setAttribute("aria-label", "Find in document");

    const input = document.createElement("input");
    input.className = "find-panel__input";
    input.type = "search";
    input.placeholder = "Find in document";
    input.setAttribute("aria-label", "Find in document");
    input.setAttribute("spellcheck", "false");

    const count = document.createElement("p");
    count.className = "find-panel__count";
    count.setAttribute("aria-live", "polite");

    const previousButton = document.createElement("button");
    previousButton.className = "find-panel__button";
    previousButton.type = "button";
    previousButton.textContent = "\u2191";
    previousButton.setAttribute("aria-label", "Previous match");
    previousButton.addEventListener("click", () => jumpToSearchMatch(-1));

    const nextButton = document.createElement("button");
    nextButton.className = "find-panel__button";
    nextButton.type = "button";
    nextButton.textContent = "\u2193";
    nextButton.setAttribute("aria-label", "Next match");
    nextButton.addEventListener("click", () => jumpToSearchMatch(1));

    const closeButton = document.createElement("button");
    closeButton.className = "find-panel__button find-panel__button--close";
    closeButton.type = "button";
    closeButton.textContent = "\u2715";
    closeButton.setAttribute("aria-label", "Close find");
    closeButton.addEventListener("click", closeFindBar);

    input.addEventListener("input", () => updateSearch(input.value));
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        jumpToSearchMatch(event.shiftKey ? -1 : 1);
      } else if (event.key === "Escape") {
        event.preventDefault();
        closeFindBar();
      }
    });

    panel.append(input, count, previousButton, nextButton, closeButton);
    document.body.appendChild(panel);

    searchState.panelEl = panel;
    searchState.inputEl = input;
    searchState.countEl = count;
    updateSearchCountLabel();
  }

  function setError(message) {
    contentEl.innerHTML = "";
    const errorEl = document.createElement("p");
    errorEl.className = "document__error";
    errorEl.textContent = message;
    contentEl.appendChild(errorEl);
  }

  function decodeBase64Utf8(value) {
    const binary = window.atob(value || "");
    const bytes = new Uint8Array(binary.length);

    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }

    return decoder.decode(bytes);
  }

  function applyBaseUrl(baseUrl) {
    if (!baseUrl) {
      return;
    }

    let baseEl = document.querySelector("base");
    if (!baseEl) {
      baseEl = document.createElement("base");
      document.head.prepend(baseEl);
    }

    baseEl.href = baseUrl;
  }

  function finalizeLinks(root) {
    const anchors = root.querySelectorAll("a[href]");

    for (const anchor of anchors) {
      const href = anchor.getAttribute("href") || "";

      if (/^https?:\/\//i.test(href)) {
        anchor.setAttribute("target", "_blank");
        anchor.setAttribute("rel", "noopener noreferrer");
      }
    }
  }

  function finalizeImages(root) {
    const images = root.querySelectorAll("img");

    for (const image of images) {
      image.loading = "lazy";
      image.decoding = "async";
    }
  }

  function disableTaskCheckboxes(root) {
    const checkboxes = root.querySelectorAll('input[type="checkbox"]');

    for (const checkbox of checkboxes) {
      checkbox.disabled = true;
    }
  }

  initTheme();

  if (!payloadEl) {
    setError("Preview data is missing.");
    createToggleButton();
    return;
  }

  if (!window.marked || !window.DOMPurify) {
    setError("Renderer assets failed to load.");
    createToggleButton();
    return;
  }

  let payload;

  try {
    const rawPayload = JSON.parse(payloadEl.textContent || "{}");

    payload = {
      filename: decodeBase64Utf8(rawPayload.filename),
      sourcePath: decodeBase64Utf8(rawPayload.sourcePath),
      baseUrl: decodeBase64Utf8(rawPayload.baseUrl),
      markdown: decodeBase64Utf8(rawPayload.markdown),
    };
  } catch (error) {
    console.error(error);
    setError("Preview data could not be decoded.");
    createToggleButton();
    return;
  }

  applyBaseUrl(payload.baseUrl);

  document.title = payload.filename || document.title;

  try {
    const renderedHtml = window.marked.parse(payload.markdown || "", {
      gfm: true,
      breaks: true,
    });

    const sanitizedHtml = window.DOMPurify.sanitize(renderedHtml, {
      USE_PROFILES: { html: true },
      ALLOW_UNKNOWN_PROTOCOLS: false,
      FORBID_TAGS: ["script", "style"],
    });

    renderedContentHtml = sanitizedHtml || "<p></p>";
    applyRenderedContent();

    const firstHeading = contentEl.querySelector("h1");
    if (firstHeading && firstHeading.textContent.trim()) {
      renderedDocumentTitle = firstHeading.textContent.trim();
      document.title = renderedDocumentTitle;
    } else {
      renderedDocumentTitle = payload.filename || document.title;
    }
  } catch (error) {
    console.error(error);
    setError("Markdown preview failed to render.");
  }

  window.mdvOpenFindBar = openFindBar;
  window.mdvToggleFindBar = toggleFindBar;
  window.mdvFindNextMatch = () => jumpToSearchMatch(1);
  window.mdvFindPreviousMatch = () => jumpToSearchMatch(-1);
  window.mdvCloseFindBar = closeFindBar;

  createSearchPanel();
  createToggleButton();
})();
