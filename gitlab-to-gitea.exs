require Logger

# install dependencies
Mix.install([
  {:req, "~> 0.5.0"}
])

# read config
[
  gitlab_to_gitea: config
] = Config.Reader.read!("./config.exs")

# API Client for GitLab
defmodule GitlabAPI do
  @moduledoc "API client for GitLab"

  def build_client(host, token) do
    Req.new(
      base_url: host,
      auth: {:bearer, token},
      receive_timeout: :timer.minutes(60)
    )
  end

  def list_users(client) do
    client
    |> Req.get!(
      url: "/api/v4/users",
      params: [
        page: 1,
        per_page: 100,
        humans: true,
        exclude_internal: true
      ]
    )
    |> then(fn %{status: 200, body: body} -> body end)
    |> Enum.map(fn user ->
      %{
        id: user["id"],
        email: user["email"],
        name: user["name"],
        username: user["username"],
        slug: user["username"],
        private_profile: user["private_profile"],
        external: user["external"],
        can_create_group: user["can_create_group"],
        can_create_project: user["can_create_project"],
        state: user["state"]
      }
    end)
  end

  def list_groups(client) do
    client
    |> Req.get!(
      url: "/api/v4/groups",
      params: [
        page: 1,
        per_page: 100
      ]
    )
    |> then(fn %{status: 200, body: body} -> body end)
    |> Enum.map(fn group ->
      %{
        id: group["id"],
        name: group["full_name"],
        slug: group["full_path"],
        description: group["description"],
        visibility: group["visibility"]
      }
    end)
  end

  def list_group_projects(client, group_id) do
    client
    |> Req.get!(
      url: "/api/v4/groups/#{group_id}/projects",
      params: [
        page: 1,
        per_page: 100
      ]
    )
    |> then(fn %{status: 200, body: body} -> body end)
    |> Enum.map(fn project ->
      %{
        id: project["id"],
        name: project["name"],
        slug: project["path"],
        description: project["description"],
        url: project["http_url_to_repo"],
        visibility: project["visibility"]
      }
    end)
  end

  def list_user_projects(client, user_id) do
    client
    |> Req.get!(
      url: "/api/v4/users/#{user_id}/projects",
      params: [
        page: 1,
        per_page: 100
      ]
    )
    |> then(fn %{status: 200, body: body} -> body end)
    |> Enum.map(fn project ->
      %{
        id: project["id"],
        name: project["name"],
        slug: project["path"],
        description: project["description"],
        url: project["http_url_to_repo"],
        visibility: project["visibility"]
      }
    end)
  end
end

# API Client for Gitea
defmodule GiteaAPI do
  @moduledoc "API client for Gitea"

  def build_client(host, token) do
    Req.new(
      base_url: host,
      auth: {:bearer, token},
      receive_timeout: :timer.minutes(60)
    )
  end

  def get_organization(client, gitlab_group) do
    case Req.get!(
           client,
           url: "/api/v1/orgs/#{gitlab_group.slug}"
         ) do
      %{status: 200, body: body} -> body
      %{status: 404} -> nil
    end
  end

  def create_organization(client, gitlab_group) do
    client
    |> Req.post!(
      url: "/api/v1/orgs",
      json: %{
        full_name: gitlab_group.name,
        username: gitlab_group.slug,
        description: gitlab_group.description,
        visibility: gitlab_visibility_to_gitea(gitlab_group.visibility)
      }
    )
    |> then(fn %{status: 201, body: body} -> body end)
  end

  def update_organization(client, gitlab_group) do
    client
    |> Req.patch!(
      url: "/api/v1/orgs/#{gitlab_group.slug}",
      json: %{
        full_name: gitlab_group.name,
        username: gitlab_group.slug,
        description: gitlab_group.description,
        visibility: gitlab_visibility_to_gitea(gitlab_group.visibility)
      }
    )
    |> then(fn %{status: 200, body: body} -> body end)
  end

  def get_repository(client, gitlab_entity, gitlab_project) do
    case Req.get!(
           client,
           url: "/api/v1/repos/#{gitlab_entity.slug}/#{gitlab_project.slug}"
         ) do
      %{status: 200, body: body} -> body
      %{status: 404} -> nil
    end
  end

  def delete_repository(client, gitlab_entity, gitlab_project) do
    client
    |> Req.delete!(url: "/api/v1/repos/#{gitlab_entity.slug}/#{gitlab_project.slug}")
    |> then(fn %{status: 204, body: body} -> body end)
  end

  def get_user(client, gitlab_user) do
    case Req.get!(
           client,
           url: "/api/v1/users/#{gitlab_user.username}"
         ) do
      %{status: 200, body: body} -> body
      %{status: 404} -> nil
    end
  end

  def create_user(client, gitlab_user) do
    client
    |> Req.post!(
      url: "/api/v1/admin/users",
      json: %{
        email: gitlab_user.email,
        full_name: gitlab_user.name,
        login_name: gitlab_user.username,
        password: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
        must_change_password: true,
        restricted: gitlab_user.external,
        send_notify: false,
        username: gitlab_user.username,
        visibility: (gitlab_user.private_profile && "private") || "public"
      }
    )
    |> then(fn %{status: 201, body: body} -> body end)
  end

  def set_user_permissions(client, gitlab_user) do
    client
    |> Req.patch!(
      url: "/api/v1/admin/users/#{gitlab_user.username}",
      json: %{
        login_name: gitlab_user.username,
        active: gitlab_user.state == "active",
        allow_create_organization: gitlab_user.can_create_group,
        max_repo_creation: (gitlab_user.can_create_project && nil) || -1,
        prohibit_login: true
      }
    )
    |> then(fn %{status: 200, body: body} -> body end)
  end

  def perform_migration(client, gitlab_token, gitlab_entity, gitlab_project) do
    client
    |> Req.post!(
      url: "/api/v1/repos/migrate",
      json: %{
        auth_token: gitlab_token,
        clone_addr: gitlab_project.url,
        issues: true,
        labels: true,
        lfs: true,
        milestones: true,
        mirror: false,
        private: gitlab_project.visibility == "private",
        pull_requests: true,
        releases: true,
        repo_name: gitlab_project.slug,
        repo_owner: gitlab_entity.slug,
        description: gitlab_project.description,
        service: "gitlab",
        wiki: true
      }
    )
    |> then(fn %{status: 201, body: body} -> body end)
  end

  defp gitlab_visibility_to_gitea("public"), do: "public"
  defp gitlab_visibility_to_gitea("internal"), do: "limited"
  defp gitlab_visibility_to_gitea("private"), do: "private"
end

Logger.info(
  "Starting migration from GitLab at #{config[:gitlab_host]} to Gitea at #{config[:gitea_host]}"
)

# build API clients
gitlab_client = GitlabAPI.build_client(config[:gitlab_host], config[:gitlab_token])
gitea_client = GiteaAPI.build_client(config[:gitea_host], config[:gitea_token])

# fetch all users from GitLab
gitlab_users = GitlabAPI.list_users(gitlab_client)
Logger.info("Found #{length(gitlab_users)} GitLab users")

# iterate over all users on GitLab, create them if necessary and fetch their projects
users_projects_list =
  Enum.map(gitlab_users, fn gitlab_user ->
    Logger.info("Processing GitLab user #{gitlab_user.username}")

    # check if user exists
    case GiteaAPI.get_user(gitea_client, gitlab_user) do
      nil ->
        # user does not exist, create it
        Logger.info("Creating user #{gitlab_user.username}")
        GiteaAPI.create_user(gitea_client, gitlab_user)
        GiteaAPI.set_user_permissions(gitea_client, gitlab_user)

      _org ->
        # user exists, skip it
        Logger.info("User #{gitlab_user.username} exists, skipping")
    end

    # fetch all projects of GitLab user
    gitlab_user_projects = GitlabAPI.list_user_projects(gitlab_client, gitlab_user.id)

    Logger.info(
      "Found #{length(gitlab_user_projects)} projects of GitLab user #{gitlab_user.username}"
    )

    {:user, gitlab_user, gitlab_user_projects}
  end)

# fetch all groups from GitLab
gitlab_groups = GitlabAPI.list_groups(gitlab_client)
Logger.info("Found #{length(gitlab_groups)} GitLab groups")

# iterate over all groups on GitLab, create or update them if necessary and fetch their projects
groups_projects_list =
  Enum.map(gitlab_groups, fn gitlab_group ->
    Logger.info("Processing GitLab group #{gitlab_group.name}")

    # check if organization exists
    case GiteaAPI.get_organization(gitea_client, gitlab_group) do
      nil ->
        # organization does not exist, create it
        Logger.info("Creating organization #{gitlab_group.name}")
        GiteaAPI.create_organization(gitea_client, gitlab_group)

      _org ->
        # organization exists, update it
        Logger.info("Organization #{gitlab_group.name} exists, updating")
        GiteaAPI.update_organization(gitea_client, gitlab_group)
    end

    # fetch all projects of GitLab group
    gitlab_group_projects = GitlabAPI.list_group_projects(gitlab_client, gitlab_group.id)

    Logger.info(
      "Found #{length(gitlab_group_projects)} projects in GitLab group #{gitlab_group.name}"
    )

    {:group, gitlab_group, gitlab_group_projects}
  end)

# finally, iterate over all groups and users and migrate their projects
for {_type, gitlab_entity, gitlab_projects} <- users_projects_list ++ groups_projects_list do
  # iterate over all projects in the GitLab group or user
  for gitlab_project <- gitlab_projects do
    Logger.info("Processing GitLab project #{gitlab_entity.slug}/#{gitlab_project.slug}")

    # check if the repository exists
    case GiteaAPI.get_repository(gitea_client, gitlab_entity, gitlab_project) do
      nil ->
        # repository does not exist, migrate it
        Logger.info(
          "Migrating repository #{gitlab_entity.slug}/#{gitlab_project.slug} - this may take a while"
        )

        GiteaAPI.perform_migration(
          gitea_client,
          config[:gitlab_token],
          gitlab_entity,
          gitlab_project
        )

      _repo ->
        # repository exists, check if we should delete it
        if config[:delete_projects] do
          # delete the repository and migrate it
          Logger.warning(
            "Repository #{gitlab_entity.slug}/#{gitlab_project.slug} already exists, deleting"
          )

          GiteaAPI.delete_repository(gitea_client, gitlab_entity, gitlab_project)

          Logger.info(
            "Migrating repository #{gitlab_entity.slug}/#{gitlab_project.slug} - this may take a while"
          )

          GiteaAPI.perform_migration(
            gitea_client,
            config[:gitlab_token],
            gitlab_entity,
            gitlab_project
          )
        else
          # skip the repository
          Logger.warning(
            "Repository #{gitlab_entity.slug}/#{gitlab_project.slug} already exists, skipping"
          )
        end
    end
  end
end

# we're done!
Logger.info("Migration completed")
