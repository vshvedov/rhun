(() => {
  "use strict";

  const descriptions = {
    hero: "rhun with a file explorer, syntax highlighting, and a live coding agent session",
    terminal: "The built-in terminal in rhun, showing a build and Git log below the editor",
    git: "Git history in rhun with a commit graph, tags, and uncommitted changes",
    agents: "The agents panel in rhun following a live Codex session"
  };
  let selectedTheme = "hero";
  let selectedThemeLabel = "Rhun Dark";
  const playButton = document.querySelector(".promo-play");
  const lightbox = document.querySelector("#promo-lightbox");
  const video = lightbox.querySelector("video");

  playButton.addEventListener("click", () => {
    lightbox.showModal();
    document.body.classList.add("video-open");
    video.play().catch(() => {});
  });
  lightbox.querySelector(".promo-close").addEventListener("click", () => lightbox.close());
  lightbox.addEventListener("click", event => {
    if (event.target !== lightbox) return;
    const bounds = lightbox.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right ||
        event.clientY < bounds.top || event.clientY > bounds.bottom) lightbox.close();
  });
  lightbox.addEventListener("close", () => {
    video.pause();
    video.currentTime = 0;
    document.body.classList.remove("video-open");
  });

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let currentView = "hero";
  function editorScreenshot() {
    return document.documentElement.dataset.colorScheme === "light" ? "hero-light" : "hero";
  }
  document.addEventListener("appearancechange", () => {
    if (currentView === "hero") setScreenshot(document.querySelector("#editor-image"), editorScreenshot(), descriptions.hero);
  });
  setScreenshot(document.querySelector("#editor-image"), editorScreenshot(), descriptions.hero);

  function setScreenshot(image, name, alt) {
    image.srcset = `img/${name}-800.webp 800w, img/${name}.webp 1600w`;
    image.src = `img/${name}.webp`;
    image.alt = alt;
    if (!reducedMotion.matches) image.animate([{ opacity: .5 }, { opacity: 1 }], { duration: 300, easing: "ease-out" });
  }

  const viewButtons = document.querySelectorAll("[data-view]");
  viewButtons.forEach(button => {
    button.addEventListener("click", () => {
      const name = button.dataset.view;
      currentView = name;
      playButton.hidden = name !== "hero";
      viewButtons.forEach(item => item.setAttribute("aria-pressed", String(item === button)));
      document.querySelectorAll("[data-description]").forEach(item => {
        item.hidden = item.dataset.description !== name;
      });
      document.querySelector(".theme-controls").hidden = name !== "themes";
      if (name === "themes") {
        setScreenshot(document.querySelector("#editor-image"), selectedTheme, `rhun in the ${selectedThemeLabel} theme`);
        return;
      }
      setScreenshot(document.querySelector("#editor-image"), name === "hero" ? editorScreenshot() : name, descriptions[name]);
    });
  });

  const themeButtons = document.querySelectorAll("[data-theme]");
  themeButtons.forEach(button => {
    button.addEventListener("click", () => {
      const label = button.getAttribute("aria-label");
      themeButtons.forEach(item => item.setAttribute("aria-pressed", String(item === button)));
      selectedTheme = button.dataset.theme;
      selectedThemeLabel = label;
      setScreenshot(document.querySelector("#editor-image"), selectedTheme, `rhun in the ${label} theme`);
      document.querySelector("#theme-name").textContent = label;
    });
  });

  document.querySelectorAll("[data-copy]").forEach(button => {
    let resetTimer;
    button.addEventListener("click", async () => {
      const status = button.parentElement.querySelector(".copy-status");
      clearTimeout(resetTimer);
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        status.textContent = button.dataset.copyMessage || "Copied. Paste it into your terminal to install.";
        button.textContent = "Copied ✓";
        resetTimer = setTimeout(() => { button.textContent = "Copy command"; }, 2200);
      } catch {
        status.textContent = "Select and copy the command above to install.";
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(button.parentElement.querySelector(".command code"));
        selection.removeAllRanges();
        selection.addRange(range);
      }
    });
  });

  // The editor preview remains usable without its optional lighting effect.
  import("./hero.js?v=@ASSET_VERSION@").catch(() => {});
})();
