const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const closeDuration = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--modal-close-dur")) || 150;

function setUpModal(dialog) {
  const panel = dialog.querySelector(".t-modal");
  let opener;

  function open(trigger) {
    if (dialog.open) return;
    opener = trigger;
    dialog.showModal();
    void panel.offsetWidth;
    dialog.classList.add("is-open");
    panel.classList.add("is-open");
  }

  function close() {
    if (!dialog.open || panel.classList.contains("is-closing")) return;
    panel.classList.replace("is-open", "is-closing");
    dialog.classList.remove("is-open");
    if (reducedMotion.matches) dialog.close();
    else setTimeout(() => dialog.close(), closeDuration);
  }

  for (const control of dialog.querySelectorAll("[data-modal-close]")) control.addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    close();
  });
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) close();
  });
  dialog.addEventListener("close", () => {
    panel.classList.remove("is-open", "is-closing");
    dialog.classList.remove("is-open");
    opener?.focus();
  });

  return open;
}

const openPairing = setUpModal(document.querySelector("#pair-preview"));
for (const trigger of document.querySelectorAll("[data-pair-preview]")) {
  trigger.hidden = false;
  trigger.addEventListener("click", () => openPairing(trigger));
}

// Screenshots open in place. Without this script their links still lead to the image.
const viewer = document.querySelector("#shot-viewer");
const viewerImage = viewer.querySelector("img");
const openViewer = setUpModal(viewer);
for (const link of document.querySelectorAll("a[data-zoom]")) {
  link.addEventListener("click", (event) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const shot = link.querySelector("img");
    viewerImage.width = shot.naturalWidth || shot.width;
    viewerImage.height = shot.naturalHeight || shot.height;
    viewerImage.alt = shot.alt;
    viewerImage.src = link.href;
    openViewer(link);
  });
}

if (navigator.clipboard) {
  for (const block of document.querySelectorAll(".code")) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "Copy";
    button.setAttribute("aria-live", "polite");
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(block.querySelector("code").textContent);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Not copied";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1600);
    });
    block.prepend(button);
  }
}

// The pill in the header follows the section being read.
const header = document.querySelector(".site-header");
const nav = document.querySelector(".site-nav");
const pill = nav.querySelector(".t-tabs-pill");
const links = [...nav.querySelectorAll(".t-tab")];
const sections = links.map((link) => document.querySelector(link.hash));
let active;

function sectionInView() {
  const line = header.offsetHeight + 48;
  const atEnd = scrollY + innerHeight >= document.documentElement.scrollHeight - 2;
  let found;
  let foundTop = -Infinity;
  sections.forEach((section, index) => {
    const box = section.getBoundingClientRect();
    const chosen = links[index].hash === location.hash;
    // Side-by-side guides share a top edge: the one last asked for wins.
    const reached = box.top <= line && box.bottom > line;
    const shownAtEnd = atEnd && chosen && box.top < innerHeight && box.bottom > line;
    if (shownAtEnd) {
      found = links[index];
      foundTop = Infinity;
    } else if (reached && (box.top > foundTop + 1 || (chosen && box.top > foundTop - 1))) {
      found = links[index];
      foundTop = box.top;
    }
  });
  return found;
}

function alignNavigation(animate) {
  active = sectionInView();
  for (const link of links) {
    if (link === active) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }

  const appearing = active && !pill.classList.contains("has-current");
  if (!animate || appearing) pill.style.transition = "none";
  if (active) {
    pill.style.transform = `translateX(${active.offsetLeft}px)`;
    pill.style.width = `${active.offsetWidth}px`;
  }
  if (!animate || appearing) {
    void pill.offsetWidth;
    pill.style.removeProperty("transition");
  }
  pill.classList.toggle("has-current", Boolean(active));
}

let queued = false;
function followScroll() {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    if (sectionInView() !== active) alignNavigation(true);
  });
}

alignNavigation(false);
addEventListener("scroll", followScroll, { passive: true });
addEventListener("hashchange", () => alignNavigation(true));
new ResizeObserver(() => alignNavigation(false)).observe(nav);
