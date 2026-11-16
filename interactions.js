const dialog = document.querySelector("#pair-preview");
const pairWindow = dialog.querySelector(".t-modal");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const closeDuration = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--modal-close-dur")) || 150;
let opener;

function openPairing(trigger) {
  if (dialog.open) return;
  opener = trigger;
  dialog.showModal();
  void pairWindow.offsetWidth;
  dialog.classList.add("is-open");
  pairWindow.classList.add("is-open");
}

function closePairing() {
  if (!dialog.open || pairWindow.classList.contains("is-closing")) return;
  pairWindow.classList.replace("is-open", "is-closing");
  dialog.classList.remove("is-open");
  if (reducedMotion.matches) dialog.close();
  else setTimeout(() => dialog.close(), closeDuration);
}

for (const trigger of document.querySelectorAll("[data-pair-preview]")) {
  trigger.hidden = false;
  trigger.addEventListener("click", () => openPairing(trigger));
}
dialog.querySelector("[data-pair-close]").addEventListener("click", closePairing);
dialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  closePairing();
});
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) closePairing();
});
dialog.addEventListener("close", () => {
  pairWindow.classList.remove("is-open", "is-closing");
  dialog.classList.remove("is-open");
  opener?.focus();
});

const nav = document.querySelector(".site-nav");
const pill = nav.querySelector(".t-tabs-pill");
const links = [...nav.querySelectorAll(".t-tab")];

function alignNavigation(animate) {
  const active = links.find((link) => link.hash === location.hash);
  for (const link of links) {
    if (link === active) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }

  if (!animate) pill.style.transition = "none";
  pill.classList.toggle("has-current", Boolean(active));
  pill.style.transform = `translateX(${active?.offsetLeft ?? 0}px)`;
  pill.style.width = `${active?.offsetWidth ?? 0}px`;
  if (!animate) {
    void pill.offsetWidth;
    pill.style.removeProperty("transition");
  }
}

alignNavigation(false);
window.addEventListener("hashchange", () => alignNavigation(true));
new ResizeObserver(() => alignNavigation(false)).observe(nav);
