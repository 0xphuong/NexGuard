defmodule FzHttp.AuditLogs.AuditLog do
  use FzHttp, :schema
  use FzHttp, :changeset

  @valid_actions ~w(
    auth.login.success
    auth.login.failure
    auth.logout
    auth.mfa.verify.success
    auth.mfa.verify.failure
    auth.mfa.enroll
    auth.mfa.delete
    auth.session.expired
    auth.native.code_issued
    auth.native.token_exchange
    auth.native.refresh
    auth.native.revoke
    user.create
    user.delete
    user.role.change
    user.disable
    user.enable
    user.password.change
    device.create
    device.delete
    device.vpn.connect
    device.vpn.disconnect
    vpn.connect
    vpn.disconnect
    rule.create
    rule.delete
    config.change
    api_token.create
    api_token.delete
    oidc_provider.create
    oidc_provider.delete
    saml_provider.create
    saml_provider.delete
  )

  @valid_results ~w(success failure)

  schema "audit_logs" do
    field :actor_email, :string
    field :action,      :string
    field :target_type, :string
    field :target_id,   :string
    field :target_label,:string
    field :ip_address,  :string
    field :result,      :string, default: "success"
    field :metadata,    :map,    default: %{}

    belongs_to :actor, FzHttp.Users.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :actor_id, :actor_email,
      :action, :result,
      :target_type, :target_id, :target_label,
      :ip_address, :metadata
    ])
    |> validate_required([:action, :result])
    |> validate_inclusion(:action, @valid_actions)
    |> validate_inclusion(:result, @valid_results)
  end

  def valid_actions, do: @valid_actions
end
