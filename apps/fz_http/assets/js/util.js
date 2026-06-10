import zxcvbn from "zxcvbn"

const dateFormatter = new Intl.DateTimeFormat(
  'en-US',
  {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: 'numeric'
  }
)

const FormatTimestamp = function (timestamp) {
  if (!timestamp) {
    return "Never"
  }
  const d = new Date(timestamp)
  // Guard against legacy rows where latest_handshake got overwritten with
  // epoch 0 (1970-01-01) before the stats_updater fix. Treat anything before
  // year 2000 as "no real handshake".
  if (isNaN(d.getTime()) || d.getFullYear() < 2000) {
    return "Never"
  }
  return dateFormatter.format(d)
}

const PasswordStrength = function (password) {
  const result = zxcvbn(password)
  return result.score
}

export { PasswordStrength, FormatTimestamp }
