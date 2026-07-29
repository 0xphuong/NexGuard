import hljs from "highlight.js"
import { FormatTimestamp, PasswordStrength } from "./util.js"
import { renderConfig } from "./wg_conf.js"
import { renderQR } from "./qrcode.js"
import { fzCrypto } from "./crypto.js"

const highlightCode = function () {
  hljs.highlightAll()
}

const formatTimestamp = function () {
  let t = this.el.dataset.timestamp
  this.el.innerHTML = FormatTimestamp(t)
}

const passwordStrength = function () {
  const field = this.el
  const fieldClasses = "password input "
  const progress = document.getElementById(field.dataset.target)
  const reset = function () {
    field.className = fieldClasses
    progress.className = "is-hidden"
    progress.setAttribute("value", "0")
    progress.innerHTML = "0%"
  }
  field.addEventListener("input", () => {
    if (field.value === "") return reset()
    const score = PasswordStrength(field.value)
    switch (score) {
      case 0:
      case 1:
        field.className = fieldClasses + "is-danger"
        progress.className = "progress is-small is-danger"
        progress.setAttribute("value", "33")
        progress.innerHTML = "33%"
        break
      case 2:
      case 3:
        field.className = fieldClasses + "is-warning"
        progress.className = "progress is-small is-warning"
        progress.setAttribute("value", "67")
        progress.innerHTML = "67%"
        break
      case 4:
        field.className = fieldClasses + "is-success"
        progress.className = "progress is-small is-success"
        progress.setAttribute("value", "100")
        progress.innerHTML = "100%"
        break
      default:
        reset()
    }
  })
}

const generateKeyPair = function () {
  let kp = fzCrypto.generateKeyPair()
  this.el.value = kp.publicKey

  // XXX: Verify
  sessionStorage.setItem(kp.publicKey, kp.privateKey)
}

const clipboardCopy = function () {
  let button = this.el
  let data = button.dataset.clipboard
  button.addEventListener("click", () => {
    button.dataset.tooltip = "Copied!"
    navigator.clipboard.writeText(data)
  })
}

// v4.0.6 install-instructions component.
//
// InstallCopy — click handler that copies `data-copy` and swaps the
// button label to "Copied ✓" for 2s. Different from the older
// ClipboardCopy hook (which relies on a Bulma tooltip): here we
// swap the button's inner content because the tooltip family isn't
// loaded on the unprivileged devices page.
//
// State (`this._copyBound`, `this._copyTimer`) lives on the hook
// object so `mounted` and `updated` share it. We only bind the
// click listener once; `data-copy` is read at click time so tab
// switches (which change the attribute) don't need re-binding.
// Any pending 2s revert timer is cleared on `updated` so a tab
// switch mid-"Copied" doesn't leave the button stuck with the
// success label as the new "original".
const installCopy = function () {
  const btn = this.el
  const revertHTML = '<i class="mdi mdi-content-copy"></i><span>Copy</span>'

  if (this._copyTimer) {
    clearTimeout(this._copyTimer)
    this._copyTimer = null
    btn.innerHTML = revertHTML
    btn.classList.remove("is-copied")
  }

  if (this._copyBound) return
  this._copyBound = true

  btn.addEventListener("click", () => {
    const cmd = btn.dataset.copy || ""
    if (!cmd) return

    navigator.clipboard.writeText(cmd).then(() => {
      btn.innerHTML = '<i class="mdi mdi-check"></i><span>Copied</span>'
      btn.classList.add("is-copied")
      if (this._copyTimer) clearTimeout(this._copyTimer)
      this._copyTimer = setTimeout(() => {
        btn.innerHTML = revertHTML
        btn.classList.remove("is-copied")
        this._copyTimer = null
      }, 2000)
    })
  })
}

// OSDetect — on component mount, sniff `navigator.userAgent` and
// push `os_detected` back to the LiveView so the correct tab
// pre-selects. Only runs once per page load; server default (`:macos`)
// applies on parse failure. Fires once via `mounted`, not `updated`,
// so a re-render from `select_install_os` doesn't clobber the user's
// manual tab pick.
const osDetect = function () {
  const ua = (navigator.userAgent || "").toLowerCase()
  let os = "macos"
  if (ua.includes("windows")) os = "windows"
  else if (
    ua.includes("linux") ||
    ua.includes("android") ||
    ua.includes("cros")
  )
    os = "linux"
  else if (ua.includes("mac") || ua.includes("iphone") || ua.includes("ipad"))
    os = "macos"

  this.pushEvent("os_detected", { os: os })
}

let Hooks = {}
Hooks.ClipboardCopy = {
  mounted: clipboardCopy,
  updated: clipboardCopy
}
Hooks.HighlightCode = {
  mounted: highlightCode,
  updated: highlightCode
}
Hooks.FormatTimestamp = {
  mounted: formatTimestamp,
  updated: formatTimestamp
}
Hooks.PasswordStrength = {
  mounted: passwordStrength,
  updated: passwordStrength
}
Hooks.RenderConfig = {
  mounted: renderConfig,
  updated: renderConfig
}
Hooks.RenderQR = {
  mounted: renderQR,
  updated: renderQR
}
Hooks.GenerateKeyPair = {
  mounted: generateKeyPair
}
Hooks.InstallCopy = {
  mounted: installCopy,
  updated: installCopy
}
Hooks.OSDetect = {
  mounted: osDetect
}

export default Hooks
