import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./style.css";
import { installNativeBridge } from "./nativeBridge";
installNativeBridge().then(() => {
  createRoot(document.getElementById("root")!).render(<App />);
}).catch((error) => {
  document.getElementById("root")!.textContent = `Unable to start blank_: ${error.message}`;
});
