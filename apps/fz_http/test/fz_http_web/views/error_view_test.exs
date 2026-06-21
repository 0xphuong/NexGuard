defmodule FzHttpWeb.ErrorViewTest do
  use FzHttpWeb.ConnCase, async: true

  # Bring render/3 and render_to_string/3 for testing custom views
  import Phoenix.View

  test "renders 404.html" do
    assert render_to_string(FzHttpWeb.ErrorView, "404.html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(FzHttpWeb.ErrorView, "500.html", []) == "Internal Server Error"
  end

  # Regression: Phoenix routes-with-no-match inject the
  # %Phoenix.Router.NoRouteError{} struct into assigns as :reason.
  # Earlier the view returned that struct verbatim and the HTML
  # renderer crashed searching for Phoenix.HTML.Safe impl. The view
  # must always emit a plain string regardless of assigns content.
  test "renders 404.html as a plain string even when :reason is a struct" do
    assert render_to_string(FzHttpWeb.ErrorView, "404.html",
             reason: %ArgumentError{message: "irrelevant"}
           ) == "Not Found"
  end

  test "renders 503.json as a JSON-safe map (template_not_found path)" do
    assert Phoenix.View.render(FzHttpWeb.ErrorView, "503.json", []) ==
             %{"error" => "service_unavailable"}
  end
end
