# Acknowledgements

I would like first to thank [gera2ld](https://github.com/gera2ld) for his work on [ai.nvim](https://github.com/gera2ld/ai.nvim), because this plugin is a fork of his work.
Without his plugin, there wouldnt be this one.
Thank you Gerald for your work.

# code-ai.nvim

A Neovim plugin that sends prompts to Anthropic, GoogleAI, and OpenAI, can optionally route large requests through external agents, and includes an Ollama-powered prompt rewording command.

Here is a demo without using the agents:

[![Demonstration](https://img.youtube.com/vi/fkVt4ozc-w8/0.jpg)](https://www.youtube.com/watch?v=fkVt4ozc-w8)

Here is a demo using the agents:

[![Demonstration](https://img.youtube.com/vi/Mmv7dKrak7Q/0.jpg)](https://www.youtube.com/watch?v=Mmv7dKrak7Q)

## Features

- Anthropic, GoogleAI, and OpenAI support
- Two execution modes:
  - **standalone**: direct API calls from Neovim
  - **agent**: requests sent to external agent servers
- Automatic routing between standalone and agent mode based on scanned file size
- Project-context scanning from `.ai-scanned-files`
- Custom prompt commands
- Built-in popup results
- Optional upload of model output to an external endpoint
- Optional usage-stat ingestion
- Local prompt rewording through Ollama

## How it works

For every configured prompt command, the plugin:

1. collects the selected text or command argument
2. loads system instructions from `.ai-system-instructions.md` when present
3. reads project files listed by `.ai-scanned-files`
4. decides whether to run in standalone or agent mode
5. resolves the model pipeline (`plan`, `reword`, `implement`):
   - **`plan` (optional)**: generates a preliminary high-level plan based on the request and `.ai-scanned-files` (never returns full file contents).
   - **`reword` (optional)**: refines the plan output into an implementation prompt enforcing full file contents (never diffs or snippets).
   - If either `plan` or `reword` is unset/nil, the planning stage is skipped.
   - **`implement` (mandatory)**: produces the complete modified or newly created file contents.
6. executes the pipeline sequentially and shows live status (`[1/3] Planning`, `[2/3] Rewording plan`, `[3/3] Implementing`) in a floating popup
7. renders the final result in the floating popup

### Standalone mode

Standalone mode sends requests directly to the provider APIs from Neovim.

- It can still include scanned project files
- It builds a multi-turn conversation locally before calling the provider API
- It does not require `*_agent_host` options

### Agent mode

Agent mode sends the request to your external agents.

- It uploads the API key, system instructions, selected project files, and prompt as separate chunks
- The final prompt triggers the model call on the agent side
- It requires the corresponding `*_agent_host` option

### How mode selection works

Each prompt runs in one of these ways:

- `query_mode = 'standalone'`: always use standalone mode
- `query_mode = 'agent'`: always use agent mode
- no `query_mode`: automatic selection

Automatic selection uses `.ai-scanned-files`:

- if no files are matched, standalone mode is used
- if matched files total less than `agent_size_threshold_bytes`, standalone mode is used
- if matched files total is greater than or equal to `agent_size_threshold_bytes`, agent mode is used

Default `agent_size_threshold_bytes` is `102400`.

If agent mode is selected but the matching `*_agent_host` option is empty, the command fails with an agent configuration error.

## The agent

You can find the agent in the repository [code-ai-agent](https://github.com/rakotomandimby/code-ai-agent).

## Valid effort / thinking levels by provider

This project allows configuring provider-specific effort/thinking levels by appending `:effort_level` to the model name (for example, `claude-sonnet-5:high` or `gemini-3.5-flash:medium`). The parsing logic splits on the `:` separator, keeps the base model ID, and maps the suffix to the provider's valid effort/thinking field. If no colon is present or if an unrecognized suffix is provided, the model name is passed through unchanged so model existence and parameters can be validated directly by the upstream API.

### OpenAI Responses API

OpenAI `reasoning.effort` valid values for the GPT-6 family are:

- `low`
- `medium`
- `high`
- `xhigh`
- `max`
- `none` (supported only on some GPT-6 variants; not a universal value)

When specified as `:none`, reasoning effort is set to `"none"`. Models configured without a `:` separator omit the `reasoning` parameter entirely to keep non-reasoning models predictable and compatible.

### Anthropic Claude 5.5

Anthropic valid effort values are:

- `low`
- `medium`
- `high`
- `xhigh`
- `max`

Anthropic accepted `thinking.type` values are:

- `adaptive`
- `between_tools`

For Sonnet 5.5, `:none` maps to `between_tools` as the safe replacement for the invalid `disabled` request. Models configured without a `:` separator omit effort and thinking configuration entirely.

### Google Vertex AI / Gemini

For Gemini 3.5 Flash Lite and 3.8 Flash, the valid `thinkingConfig.thinkingLevel` values are:

- `minimal`
- `low`
- `medium`
- `high`

For Gemini 3.5 Flash Lite, `minimal` is the lowest-cost/default setting; for Gemini 3.8 Flash, `low` is the lowest-cost/default setting. When `:none` is specified, it maps to the cheapest valid level (`low` for Gemini 3.7+, otherwise `minimal`). Models configured without a `:` separator omit `thinkingConfig` to use API defaults.

### Valid suffix map used by the project

| Provider | Valid suffixes (e.g. `model:level`) | Behavior for `:none` | Behavior without `:` or unknown suffix |
| --- | --- | --- | --- |
| OpenAI | `low`, `medium`, `high`, `xhigh`, `max`, `none` | `reasoning.effort = "none"` | Pass model unchanged (no reasoning effort set) |
| Anthropic | `low`, `medium`, `high`, `xhigh`, `max`, `none` | `thinking = { type = "between_tools" }` | Pass model unchanged (no effort/thinking set) |
| GoogleAI | `minimal`, `low`, `medium`, `high`, `none` | Cheapest valid level (`low` for Gemini 3.7+, otherwise `minimal`) | Pass model unchanged (no thinkingLevel set) |

## Installation

First get API keys from:

- [Google Cloud](https://ai.google.dev/gemini-api/docs/api-key)
- [OpenAI](https://platform.openai.com/api-keys)
- [Anthropic](https://console.anthropic.com/settings/keys)

Example with `lazy.nvim`:

```lua
{
    'code-ai-nvim/code-ai.nvim',
    dependencies = {
        'nvim-lua/plenary.nvim',
    },
    opts = {
        models = {
            { plan      = 'anthropic/claude-sonnet-5:high' },
            { implement = 'googleai/gemini-3.5-flash:medium' },
            { reword    = 'openai/gpt-4o-mini' },
        },

        anthropic_api_key = os.getenv('ANTHROPIC_API_KEY'),
        googleai_api_key = os.getenv('GOOGLEAI_API_KEY'),
        openai_api_key = os.getenv('OPENAI_API_KEY'),

        anthropic_agent_host = 'http://127.0.0.1:6000',
        googleai_agent_host = 'http://127.0.0.1:5000',
        openai_agent_host = 'http://127.0.0.1:4000',

        ollama_host = 'http://127.0.0.1:11434',
        ollama_model = 'llama3.2',

        agent_size_threshold_bytes = 102400,
        locale = 'en',
        alternate_locale = 'fr',
        result_popup_gets_focus = false,

        upload_url = '',
        upload_token = '',
        upload_as_public = false,

        stats_ingestion_token = '',

        prompts = {
            explain = {
                command = 'AIExplain',
                prompt_tpl = [[Explain this code: ${input}]],
                result_tpl = '${output}',
                loading_tpl = 'Loading...',
                require_input = true,
                models = {
                    { plan      = nil },
                    { implement = 'anthropic/claude-sonnet-5:low' },
                    { reword    = nil },
                },
            },
            refactor = {
                command = 'AIRefactor',
                prompt_tpl = [[Refactor this code: ${input}]],
                query_mode = 'standalone',
                require_input = true,
                models = {
                    { plan      = 'anthropic/claude-sonnet-5:high' },
                    { implement = 'googleai/gemini-3.5-flash:medium' },
                    { reword    = 'openai/gpt-4o-mini' },
                },
            },
        },
    },
}
```

### Provider and model configuration

Models are configured using the format `<provider>/<model>` (e.g. `anthropic/claude-sonnet-5:high`, `googleai/gemini-3.5-flash:medium`, `openai/gpt-4o-mini`). Supported providers are `anthropic`, `googleai`, and `openai`.

Each prompt (or the global `opts.models` default) defines the model pipeline:

- **`plan` (optional)**: The model used to generate an initial high-level execution plan based on the user request and `.ai-scanned-files`. **Never** outputs full file contents. If `nil` or omitted, the plan step is skipped.
- **`implement` (mandatory)**: The model that produces the final code. It receives the prompt, reworded plan (if planning occurred), and scanned project files. **Must always** return the full, complete new content of all files to modify or create, and **never** diffs or code snippets.
- **`reword` (optional)**: The model that refines the output of the `plan` step into a continuation prompt for `implement`, enforcing complete file generation. **If no `reword` model is specified (or set to `nil`), the `plan` step is skipped entirely** and execution proceeds directly to `implement` with the original prompt.

Both array syntax and flat table syntax are supported:

```lua
-- Array of single-key tables
models = {
    { plan      = 'anthropic/claude-sonnet-5:high' },
    { implement = 'googleai/gemini-3.5-flash:medium' },
    { reword    = 'openai/gpt-4o-mini' },
}

-- Or flat table
models = {
    plan      = 'anthropic/claude-sonnet-5:high',
    implement = 'googleai/gemini-3.5-flash:medium',
    reword    = 'openai/gpt-4o-mini',
}
```

To skip planning for a prompt, leave `plan` and `reword` as `nil` (or omit them):

```lua
models = {
    { plan      = nil },
    { implement = 'anthropic/claude-sonnet-5:low' },
    { reword    = nil },
}
```

A prompt without a valid `implement` model or without an API key configured for its referenced provider will abort with an explanatory error popup.

### Agent configuration

Set `anthropic_agent_host`, `googleai_agent_host`, and/or `openai_agent_host` only if you want agent mode to be available for that provider.

### Ollama configuration

Set `ollama_host` and `ollama_model` if you want to use `:AIRewordPrompt`.

## Project files and system instructions

### `.ai-scanned-files`

`.ai-scanned-files` is optional. When present, it must contain include and exclude glob patterns:

- lines starting with `+` include files
- lines starting with `-` exclude files

Example:

```text
+**/*.lua
+*.json
-**/node_modules/**
```

The plugin detects the project root in this order:

1. directory containing `.ai-scanned-files`
2. nearest `.git` directory
3. nearest `.gitignore`
4. nearest `README.md`

Matched files are deduplicated, sorted by size, and unreadable or empty files are skipped when building provider context.

### `.ai-system-instructions.md`

`.ai-system-instructions.md` is optional and is read from the current working directory if present. The plugin automatically appends stage-specific guidance for planning, rewording, and implementation steps to ensure each model strictly adheres to output formatting requirements (e.g. planning never provides full files; implementation always provides complete files).

## Commands

### Built-in commands

| Command | Description |
| --- | --- |
| `:AIIntroduceYourself` | Runs the built-in `introduce` prompt. |
| `:AIRewordPrompt [text]` | Rewords a prompt through Ollama. If `[text]` is omitted, the current selection is used. |
| `:AIListScannedFiles` | Shows the scanned-file summary popup. |
| `:AIShowSystemInstructions` | Shows the merged system instructions popup. |

### Prompt commands

Each entry in `opts.prompts` creates a Neovim user command from its `command` field.

- Commands accept an optional argument
- If no argument is given, the plugin tries to use the current visual selection
- If `require_input = true`, the command runs only when some text with letters is available

## Usage

Typical flow:

1. select text in visual mode, or pass text as a command argument
2. run one of your configured prompt commands, for example `:AIExplain`
3. read the result in the floating popup

You can also run:

- `:AIRewordPrompt` to improve a prompt locally with Ollama
- `:AIListScannedFiles` to inspect the files currently used as project context
- `:AIShowSystemInstructions` to inspect the instructions currently sent

The popup closes automatically when the cursor moves.

## Configuration options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `models` | table | `{}` | Global default model pipeline (`plan`, `implement`, `reword`). |
| `anthropic_agent_host` | string | `''` | Anthropic agent base URL. |
| `googleai_agent_host` | string | `''` | GoogleAI agent base URL. |
| `openai_agent_host` | string | `''` | OpenAI agent base URL. |
| `anthropic_api_key` | string | `''` | Anthropic API key. |
| `googleai_api_key` | string | `''` | GoogleAI API key. |
| `openai_api_key` | string | `''` | OpenAI API key. |
| `agent_size_threshold_bytes` | number | `102400` | Default threshold used by automatic routing. |
| `ollama_host` | string | `''` | Ollama host used by `:AIRewordPrompt`. |
| `ollama_model` | string | `''` | Ollama model used by `:AIRewordPrompt`. |
| `locale` | string | `'en'` | Template placeholder value available as `${locale}`. |
| `alternate_locale` | string | `'fr'` | Template placeholder value available as `${alternate_locale}`. |
| `result_popup_gets_focus` | boolean | `false` | Give focus to the popup when it opens. |
| `upload_url` | string | `''` | Endpoint used to upload rendered provider output. |
| `upload_token` | string | `''` | Authentication token used with `upload_url`. |
| `upload_as_public` | boolean | `false` | Adds the public-upload header when uploading content. |
| `stats_ingestion_token` | string | `''` | Enables provider usage-stat submission when set. |
| `prompts` | table | built-in `introduce` prompt | Additional prompt definitions merged with built-in prompts. |

## Prompt fields

These fields are supported inside each entry of `opts.prompts`:

| Field | Required | Description |
| --- | --- | --- |
| `command` | Yes | Name of the Neovim user command to create. |
| `prompt_tpl` | Yes | Prompt template sent to the providers. |
| `loading_tpl` | No | Popup text shown while waiting for results. |
| `result_tpl` | No | Template used to render the final combined output. Defaults to `${output}`. |
| `require_input` | No | Require an argument or visual selection before running. |
| `models` | No | Model pipeline definition for this prompt (`plan`, `implement`, `reword`), overriding global `models`. |
| `query_mode` | No | Force `'standalone'` or `'agent'` for this prompt. |
| `agent_size_threshold_bytes` | No | Override the global size threshold for this prompt. |

Per-prompt API keys and per-prompt agent hosts are not supported by the current codebase; only the global options are used for those values.

## Template placeholders

The plugin replaces these placeholders in templates:

| Placeholder | Available in | Description |
| --- | --- | --- |
| `${locale}` | `prompt_tpl`, `loading_tpl`, `result_tpl` | Value of `opts.locale`. |
| `${alternate_locale}` | `prompt_tpl`, `loading_tpl`, `result_tpl` | Value of `opts.alternate_locale`. |
| `${input}` | `prompt_tpl`, `loading_tpl`, `result_tpl` | Selected text or command argument. |
| `${input_encoded}` | `prompt_tpl`, `loading_tpl`, `result_tpl` | JSON-encoded form of the input text. |
| `${output}` | `result_tpl` | Final output generated by the implementation model. |
| `${anthropic_output}` | `result_tpl` | Implementation output when Anthropic is used. |
| `${googleai_output}` | `result_tpl` | Implementation output when GoogleAI is used. |
| `${openai_output}` | `result_tpl` | Implementation output when OpenAI is used. |

## Output and history

- Each enabled provider contributes its own rendered result block
- Successful non-disabled provider results are saved under `.ai-history/`
- History is kept under the detected project root
- The plugin keeps the 15 most recent history files

## License

MIT License
