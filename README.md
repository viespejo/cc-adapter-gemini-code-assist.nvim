## Gemini Code Assist Adapter for CodeCompanion

This adapter connects to Google's Gemini Code Assist API (the internal API used by Gemini CLI and VS Code). It features an automated OAuth2 flow, automated project provisioning (Zero Config), and support for multiple Google accounts via profiles.

### Usage Tiers

The adapter automatically detects your usage tier based on your configuration:

**1. Individual Use (Zero Config)**
For users with personal Google accounts. You do not need to provide a Project ID. The adapter will automatically:
- Trigger OAuth2 authentication.
- Provision a "Managed Project" (Free Tier) via Google's onboarding API.
- Cache the project details locally.

**2. Standard or Enterprise**
For users within a Google Workspace or Google Cloud Organization.
- Requires a `project_id` from your Google Cloud Console.
- Supports organization-specific policies and models.

## File Structure

Create a directory named `gemini-code-assist` inside your CodeCompanion adapters path:

```text
lua/codecompanion/adapters/http/gemini-code-assist/
├── init.lua       (Adapter definition)
├── auth.lua       (OAuth2 manager)
└── constants.lua  (Shared configuration)
```

## Installation

1. Copy the **Auth Module** code into `lua/codecompanion/adapters/http/gemini-code-assist/auth.lua`.
2. Copy the **Adapter Definition** code into `lua/codecompanion/adapters/http/gemini-code-assist/init.lua`.

## Configuration

Add the adapter to your CodeCompanion setup. You only need to provide the `project_id` if you are an Enterprise/Standard user.

### Basic Setup (Zero Config)
If you don't provide a `project_id`, the adapter will automatically attempt to provision a "Free Tier" managed project for your Google account.

```lua
require("codecompanion").setup({
  adapters = {
    gemini_code_assist = function()
      return require("codecompanion.adapters").extend("gemini-code-assist", {
        env = {
          -- For Enterprise/Standard users:
          -- project_id = "your-gcp-project-id",
          -- or your can set the environment variable GEMINI_CODE_ASSIST_PROJECT_ID

          -- For Individual users:
          -- Leave project_id nil or unset for Zero Config
        },
      })
    end,
  },
  interactions = {
    chat = { adapter = "gemini_code_assist" },
  },
})
```

### Multi-Account Support (Profiles)
You can use multiple Google accounts by defining different profiles. Each profile maintains its own separate token file.

```lua
require("codecompanion").setup({
  adapters = {
    gemini_personal = function()
      return require("codecompanion.adapters").extend("gemini-code-assist", {
        opts = { profile = "personal" }
      })
    end,
    gemini_work = function()
      return require("codecompanion.adapters").extend("gemini-code-assist", {
        opts = { profile = "work" },
        env = {
          project_id = "my-corporate-project-id", -- Optional: force a specific project
        }
      })
    end,
  },
})
```

### Environment Variables
The adapter can automatically resolve configuration from your system environment:
- `GEMINI_CODE_ASSIST_PROJECT_ID`: Your Google Cloud Project ID.

## Authentication Flow

The adapter manages two types of tokens to ensure security and persistence:

1. **Refresh Token (Persistent)**: A long-lived token stored on disk.
    * **Initial Setup**: Automatically triggered when the adapter is resolved if no token file exists for the current profile.
    * **Manual**: Can be forced at any time using the command `:CodeCompanionGeminiAuth [profile]`.
    * **Process**: Opens your browser for authorization and uses a temporary local loopback server to capture the code.
 
 2. **Access Token (Ephemeral)**: A short-lived token sent in the headers of every request.
     * **Automatic**: Generated transparently using the *Refresh Token* before each API call.
     * **Memory Cache**: Access tokens are cached in memory and only refreshed when close to expiration (~1 hour), minimizing network overhead.

## Key Features

- **Zero Config**: Seamless project provisioning for individual developers.
- **Multi-Profile**: Support for multiple Google accounts via the `opts.profile` setting.
- **Reasoning/Thinking**: Supports Gemini 3 "Thinking" models with `reasoning_effort` and `include_thoughts`.
- **Vision**: Automatic detection of image support based on the selected model.
- **Tools**: compatible with CodeCompanion's Agents and Tools ecosystem.

## Requirements

- `curl` installed on your system.
- For Individual use: A personal Google account.
- For Enterprise/Standard use: A GCP project with the "Gemini for Google Cloud API" enabled.

## Troubleshooting

- **Project Errors**: If automated provisioning fails, ensure the "Gemini for Google Cloud API" is enabled in your [GCP Console](https://console.cloud.google.com/apis/library/cloudaicompanion.googleapis.com).
- **Port Conflicts**: The adapter uses a random free port for the authentication callback. If you are behind a strict firewall, ensure local loopback connections are allowed.
- **Logs**: Use `:CodeCompanionLog` to view detailed request/response data if authentication fails.
- **Token Location**: Tokens are stored in `stdpath("data")` as `gemini_code_assist_token_[profile].json`.
