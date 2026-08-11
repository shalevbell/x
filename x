#!/usr/bin/env bash
set -euo pipefail

readonly MAX_CONTEXT_ITEMS=100
readonly MAX_STDIN_SIZE=1048576

debug() {
  [[ ${DEBUG:-0} -eq 1 ]] && echo "DEBUG: $*" >&2
  return 0
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  cat <<EOF

  Usage: x [--debug] <instruction>           # Generate and execute commands
         <command> | x [--debug] <question>  # Analyze piped output
         x --help

  Examples:
    # Command generation mode:
    x current epoch time
    x find all python files modified today

    # Analysis mode (with piped input):
    kubectl get pods | x what are the resource limits
    docker ps | x which containers are using the most memory
    ls -la | x show me the largest files

  Options:
    --debug      Enable debug output
    --help, -h   Show this help message

    Uses the 'claude' CLI to query Claude. Requires Claude Code to be
    installed and authenticated (run 'claude /login' if needed).
    Set CLAUDE_MODEL to choose a model (e.g. 'sonnet', 'haiku', 'opus');
    defaults to whatever model Claude Code is configured to use.

EOF
  exit 0
fi

DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
fi

if ! command -v claude &> /dev/null; then
  echo "Error: claude is not installed" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: x [--debug] <instruction|question>" >&2
  echo "Run 'x --help' for more information." >&2
  exit 1
fi

USER_INPUT="$*"

# Detect mode based on stdin availability
if [[ -t 0 ]]; then
  MODE="generate"
  debug "Mode: Command generation"

  CURRENT_DIR=$(pwd)
  CURRENT_USER=$(whoami)
  CURRENT_SHELL=${SHELL}
  CURRENT_OS=$(uname -s)

  DIR_CONTENTS=$(ls -a 2>/dev/null | head -n "$MAX_CONTEXT_ITEMS" || echo "Unable to list directory")
  if [[ $(ls -a 2>/dev/null | wc -l) -gt $MAX_CONTEXT_ITEMS ]]; then
    DIR_CONTENTS="${DIR_CONTENTS}
  ... (truncated, more than $MAX_CONTEXT_ITEMS items)"
  fi

  PROMPT_TEXT=$(cat <<EOF
  You are a shell command generator. Convert the user's natural language instruction into a shell command.

  Rules:
  - Return ONLY the shell command, nothing else
  - No explanations, no markdown formatting, no code block markers
  - No backticks, no 'bash' in code blocks, no comments
  - Just the raw executable command(s)
  - If the request is too vague or not a request for a command then return the word ERROR! with an explanation
  - If you have questions but can find the answers out with commands then run them and store the answers in variables or \$() for use in the main command
  - If you need context information that isn't provided, YOU MUST discover it using commands
  - Use command substitution \$() or variables to capture and use discovered information
  - Use pipes (|) and operators (&&, ||) as needed
  - If multiple commands are needed then generate them, combine them with && or ;

  Context:
  - Current directory: ${CURRENT_DIR}
  - Content of current directory:
  ${DIR_CONTENTS}
  - Username: ${CURRENT_USER}
  - Shell: ${CURRENT_SHELL}
  - OS: ${CURRENT_OS}

  Instruction: ${USER_INPUT}

  Command:
EOF
  )
else
  MODE="analyze"
  debug "Mode: Output analysis"
  debug "Reading from stdin..."

  STDIN_DATA=$(head -c "$MAX_STDIN_SIZE")

  if [[ $(echo "$STDIN_DATA" | wc -c) -ge $MAX_STDIN_SIZE ]]; then
    STDIN_DATA="${STDIN_DATA}

  [Note: Input was truncated at ${MAX_STDIN_SIZE} bytes]"
    debug "Warning: stdin exceeded size limit and was truncated"
  fi

  if [[ -z "$STDIN_DATA" ]]; then
    echo "Error: No data received from stdin" >&2
    exit 1
  fi

  PROMPT_TEXT=$(cat <<EOF
  You are a helpful assistant that analyzes command output and answers questions.

  The user has piped the following command output to you:

  \`\`\`
  ${STDIN_DATA}
  \`\`\`

  User's question: ${USER_INPUT}

  Please provide a clear, concise answer based on the data provided. If the data doesn't contain the information needed to answer the question, explain what information is missing. Keep answers short and in plaintext. Show sections that may be relevant to the answer from the piped input together with your answer.
EOF
  )
fi

debug "Model: ${CLAUDE_MODEL:-(default)}"
debug "User input: $USER_INPUT"
debug "Prompt: $PROMPT_TEXT"

CLAUDE_ARGS=(-p --output-format text --tools "" --no-session-persistence)
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
fi

debug "Running: claude ${CLAUDE_ARGS[*]} <prompt>"

set +e
RESPONSE=$(claude "${CLAUDE_ARGS[@]}" "$PROMPT_TEXT" < /dev/null 2>&1)
CLAUDE_EXIT_CODE=$?
set -e

if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
  echo "Error: claude command failed" >&2
  echo "Details: $RESPONSE" >&2
  exit 1
fi

if [[ -z "$RESPONSE" ]]; then
  echo "Error: Received an empty response from claude" >&2
  exit 1
fi

debug "Extracted response: $RESPONSE"

if [[ "$MODE" == "generate" ]]; then
  if [[ "$RESPONSE" =~ ^ERROR!:?[[:space:]] ]]; then
    echo "$RESPONSE" >&2
    exit 1
  fi

  echo "----------"
  echo -e "\033[1;33m>>>\033[0m $RESPONSE"

  read -p "Execute this command? (Y/n): " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Command execution cancelled"
    exit 0
  else
    bash -c "$RESPONSE"
  fi
else
  echo "$RESPONSE"
fi
