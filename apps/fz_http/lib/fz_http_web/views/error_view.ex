defmodule FzHttpWeb.ErrorView do
  use FzHttpWeb, :view

  # If you want to customize a particular status code
  # for a certain format, you may uncomment below.
  # def render("500.html", _assigns) do
  #   "Internal Server Error"
  # end

  def render("404.json", _assigns) do
    %{"error" => "not_found"}
  end

  # Never pass `assigns[:reason]` straight through — it can be an
  # exception struct (e.g. `%Phoenix.Router.NoRouteError{}` raised by
  # the router on an unmatched path) and `Phoenix.HTML.Safe` has no
  # impl for arbitrary structs, so the error-renderer crashes
  # rendering the error. Always emit a plain string (HTML) or a
  # JSON-safe map.
  def template_not_found(template, _assigns) do
    status_msg = Phoenix.Controller.status_message_from_template(template)

    if String.ends_with?(template, ".json") do
      %{"error" => status_msg |> String.downcase() |> String.replace(" ", "_")}
    else
      status_msg
    end
  end
end
