"use strict";

const chinese = {
  skip: "跳到正文", navigation: "主导航", home: "Singers Lyrics 首页",
  navApp: "认识应用", navDevices: "你的设备", navSource: "GitHub ↗",
  heroEyebrow: "为你的练唱方式而设计", heroTitle: "给你的歌声", heroAccent: "留一点空间。",
  heroCopy: "把歌词、批注和歌曲时间轴放在一起。在 Mac 上准备，在 iPhone 和 iPad 上继续练习。",
  download: "下载 Mac 版", explore: "探索应用", heroNote: "开源应用 · macOS 26+ · iOS 与 iPadOS 26+",
  macEnlarge: "放大查看 Mac 截图", macLabel: "MAC 工作空间", macCaption: "曲库、编辑器与播放器，同屏呈现。",
  macAlt: "Mac 工作空间：左侧曲库，中间带有批注和时间戳的歌词编辑器，右侧同步歌词播放器。",
  highlights: "应用亮点", highlightMusic: "Apple Music 播放", highlightNotes: "逐句添加批注", highlightCloud: "可选 iCloud 同步",
  workflowEyebrow: "多一点准备，让每次练习更从容。", workflowTitle: "让每一句歌词", workflowAccent: "都有自己的提示。",
  prepareTitle: "把细节写进歌词。", prepareCopy: "突出一个字，标记一次换气，补上一条发音提示。把练唱时需要的细节放在对应的歌词旁。", prepareTag: "文字格式与批注",
  timeTitle: "找到进歌的时刻。", timeCopy: "听着关联的 Apple Music 歌曲，为每一句设置时间戳。调整好时机，再切换到播放器跟随歌词练习。", timeTag: "逐句时间同步",
  practiceTitle: "再试一次这一句。", practiceCopy: "为单句录下简短的练唱片段。回放自己的声音，让录音与正在练习的歌词保存在一起。", practiceTag: "逐句录音与回放",
  devicesEyebrow: "MAC · IPHONE · IPAD", devicesTitle: "还是那首歌，", devicesAccent: "练习多一点自由。",
  devicesIntro: "在每台设备上，以原生界面呈现你的歌词与练习内容。",
  iphoneEnlarge: "放大查看 iPhone 截图", iphoneCaption: "在 iPhone 上逐句编辑歌词、调整时间。",
  iphoneAlt: "iPhone 歌词编辑器：发音批注、彩色文字、逐句录音控件与时间调整工具。",
  iphoneTitle: "下一句，", iphoneAccent: "就在手边。", iphoneCopy: "把练习带在身边。在 iPhone 上编辑歌词、查看发音提示，或微调某一句的时间。",
  iphoneItem1: "文字格式与批注一起呈现", iphoneItem2: "每句旁都有录音控件", iphoneItem3: "随手调整歌词时间", editingGuide: "查看歌词编辑指南",
  ipadEnlarge: "放大查看 iPad 截图", ipadCaption: "iPad 上的显示与曲库设置。",
  ipadAlt: "iPad 设置页：歌词字体、专辑封面尺寸与可选的 iCloud Drive 同步设置。",
  ipadTitle: "你的界面，", ipadAccent: "由你来定。", ipadCopy: "选择默认歌词字体，调整曲库中的专辑封面显示。当你想在另一台设备上继续时，可以设置 iCloud Drive 曲库同步。",
  ipadNote: "曲库可以保存在本地。是否启用同步，由你选择。", syncGuide: "查看 iCloud 设置指南",
  startEyebrow: "为下一次练唱做好准备", startTitle: "少一点翻找，", startAccent: "多一点歌声。",
  startCopy: "从 Mac 版开始，也可以为自己的 iPhone 和 iPad 构建应用。源码与设置指南都已开放。",
  source: "在 GitHub 查看", releaseNotes: "v1.0.0 · 版本与安装说明", buildGuide: "为 iPhone 与 iPad 构建",
  footerCopy: "给你的歌声，留一点空间。", documentation: "使用文档", license: "MIT 许可证", close: "关闭截图"
};

const translations = { en: {}, "zh-CN": chinese };
const textElements = [...document.querySelectorAll("[data-i18n]")];
const altElements = [...document.querySelectorAll("[data-i18n-alt]")];
const ariaElements = [...document.querySelectorAll("[data-i18n-aria]")];
for (const element of textElements) translations.en[element.dataset.i18n] = element.textContent;
for (const element of altElements) translations.en[element.dataset.i18nAlt] = element.alt;
for (const element of ariaElements) translations.en[element.dataset.i18nAria] = element.getAttribute("aria-label");

const languageButton = document.querySelector(".language-toggle");
const dialog = document.querySelector(".lightbox");
const lightboxImage = document.querySelector(".lightbox-image");
const lightboxCaption = document.querySelector("#lightbox-caption");
let language = "en";
let activeScreenshot = null;

function setLanguage(nextLanguage) {
  language = nextLanguage;
  document.documentElement.lang = language;
  const messages = translations[language];
  for (const element of textElements) element.textContent = messages[element.dataset.i18n];
  for (const element of altElements) element.alt = messages[element.dataset.i18nAlt];
  for (const element of ariaElements) element.setAttribute("aria-label", messages[element.dataset.i18nAria]);
  languageButton.textContent = language === "en" ? "中文" : "EN";
  languageButton.setAttribute("aria-label", language === "en" ? "Switch to Chinese" : "Switch to English");
  languageButton.lang = language === "en" ? "zh-CN" : "en";
  document.title = language === "en" ? "Singers Lyrics — Make room for your voice." : "Singers Lyrics — 给你的歌声，留一点空间。";
  document.querySelector('meta[name="description"]').content = language === "en"
    ? "Prepare, synchronize, and follow lyrics on Mac, iPhone, and iPad. A native workspace for your next practice session."
    : "在 Mac、iPhone 与 iPad 上准备歌词、添加批注并同步歌曲时间。为下一次练唱留一点空间。";
  if (activeScreenshot) {
    lightboxCaption.textContent = messages[activeScreenshot.dataset.caption];
    lightboxImage.alt = activeScreenshot.querySelector("img").alt;
  }
}

let savedLanguage;
try { savedLanguage = localStorage.getItem("singers-lyrics-language"); } catch { /* Storage is optional. */ }
setLanguage(savedLanguage === "en" || savedLanguage === "zh-CN" ? savedLanguage : navigator.language.toLowerCase().startsWith("zh") ? "zh-CN" : "en");
languageButton.hidden = false;
languageButton.addEventListener("click", () => {
  setLanguage(language === "en" ? "zh-CN" : "en");
  try { localStorage.setItem("singers-lyrics-language", language); } catch { /* Keep working without storage. */ }
});

if (typeof dialog.showModal === "function") {
  for (const trigger of document.querySelectorAll("[data-lightbox]")) {
    trigger.addEventListener("click", event => {
      if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      activeScreenshot = trigger;
      lightboxImage.src = trigger.href;
      lightboxImage.alt = trigger.querySelector("img").alt;
      lightboxCaption.textContent = translations[language][trigger.dataset.caption];
      dialog.showModal();
      document.body.classList.add("modal-open");
    });
  }
  document.querySelector(".lightbox-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", event => {
    const bounds = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
  });
  dialog.addEventListener("close", () => {
    document.body.classList.remove("modal-open");
    activeScreenshot?.focus({ preventScroll: true });
    activeScreenshot = null;
  });
}
