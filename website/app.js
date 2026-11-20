const config = window.ANYREC_SITE;
if (config) {
  const button = document.getElementById("download-button");
  const url = new URL(config.purchaseUrl, window.location.href);
  if (["https:", "http:"].includes(url.protocol)) button.href = url.href;
  button.textContent = config.buttonLabel;
  document.getElementById("download-note").textContent = config.purchaseNote;
}
