#!/usr/bin/env bash
set -euo pipefail

readonly API_ENDPOINT="http://127.0.0.1:10179/v1/chat/completions"
readonly CURL_TIMEOUT=30
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

    Set LITELLM_API_KEY and LITELLM_MODEL environment variables.

EOF
  exit 0
fi

DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
fi

for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: $cmd is not installed" >&2
    exit 1
  fi
done

if [[ -z "${LITELLM_API_KEY:-}" ]]; then
  echo "Error: LITELLM_API_KEY not set" >&2
  exit 1
fi

if [[ -z "${LITELLM_MODEL:-}" ]]; then
  echo "Error: LITELLM_MODEL not set" >&2
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

debug "Model: $LITELLM_MODEL"
debug "User input: $USER_INPUT"

JSON_PAYLOAD=$(jq -n \
  --arg model "$LITELLM_MODEL" \
  --arg content "$PROMPT_TEXT" \
  '{
  model: $model,
  messages: [{role: "user", content: $content}]
  }')

debug "JSON Payload: $JSON_PAYLOAD"
debug "Sending request to LiteLLM..."

set +e
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
  --max-time "$CURL_TIMEOUT" \
  -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_API_KEY}" \
  -d "$JSON_PAYLOAD" 2>&1)
CURL_EXIT_CODE=$?
set -e

if [[ $CURL_EXIT_CODE -eq 28 ]]; then
  echo "Error: API request timed out after ${CURL_TIMEOUT}s" >&2
  exit 1
elif [[ $CURL_EXIT_CODE -ne 0 ]]; then
  debug "curl failed with exit code $CURL_EXIT_CODE"
  debug "curl output: $HTTP_RESPONSE"
  echo "Error: Failed to connect to LiteLLM API" >&2
  exit 1
fi

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

debug "Response received (HTTP $HTTP_CODE)"
debug "Full response: $RESPONSE_BODY"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: API request failed (HTTP $HTTP_CODE)" >&2
  ERROR_MSG=$(echo "$RESPONSE_BODY" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
  echo "Error details: $ERROR_MSG" >&2
  exit 1
fi

RESPONSE=$(echo "$RESPONSE_BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [[ -z "$RESPONSE" ]]; then
  echo "Error: Failed to extract response from API" >&2
  debug "API Response: $RESPONSE_BODY"
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
