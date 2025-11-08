#!/bin/bash
#
# git-commit-auto
#
# Generates a commit message using the Gemini API based on staged changes
# and performs the commit.
#
# Dependencies:
# - curl: For making API requests.
# - jq: For parsing JSON responses.
# - git: For obvious reasons.
#
# Setup:
# 1. Place this script in your PATH (e.g., /usr/local/bin/git-commit-auto).
# 2. Make it executable: chmod +x /usr/local/bin/git-commit-auto
# 3. Set your API key as an environment variable:
#    export GEMINI_API_KEY="YOUR_API_KEY_HERE"
#    (Add this to your ~/.bashrc or ~/.zshrc)

set -e
set -o pipefail


MODEL="gemini-2.5-flash-lite"
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

if [ -z "$GEMINI_API_KEY" ]; then
    echo "Error: GEMINI_API_KEY environment variable is not set."
    echo "Please set it before running this script."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install it to continue."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it to continue."
    exit 1
fi

GIT_DIFF=$(git diff --staged)

if [ -z "$GIT_DIFF" ]; then
    echo "No staged changes found. Did you forget to 'git add'?"
    exit 0
fi

SYSTEM_PROMPT="You are an expert programmer and commit message generator.
Your task is to write a concise and informative commit message for the given code diff.
The message MUST strictly follow the Conventional Commits specification.
It must be a single line, starting with a type (e.g., FEAT:, FIX:, REFACTOR:, DOCS:, STYLE:, TEST:, CHORE:), followed by a short description.
Do NOT include any extra text, explanations, or markdown formatting (like \`\`\`).
Just provide the single-line commit message."

JSON_PAYLOAD=$(jq -n \
    --arg system_prompt "$SYSTEM_PROMPT" \
    --arg diff "$GIT_DIFF" \
    '{
        "systemInstruction": { "parts": [{ "text": $system_prompt }] },
        "contents": [{ "parts": [{ "text": ("Here is the diff:\n\n" + $diff) }] }],
        "generationConfig": {
            "temperature": 0.5,
            "maxOutputTokens": 100
        }
    }')

echo "Contacting Gemini to generate commit message..."

MAX_RETRIES=3
RETRY_DELAY=1
for ((i=0; i<MAX_RETRIES; i++)); do
    RESPONSE=$(curl -s -X POST "${API_URL}?key=${GEMINI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    if echo "$RESPONSE" | jq -e '.candidates[0].content.parts[0].text' > /dev/null; then
        break
    fi

    echo "Warning: API call failed or returned an unexpected response. Retrying in ${RETRY_DELAY}s..."
    echo "Response: $RESPONSE"
    sleep $RETRY_DELAY
    RETRY_DELAY=$((RETRY_DELAY * 2))

    if [ $i -eq $((MAX_RETRIES - 1)) ]; then
        echo "Error: Max retries reached. Failed to get a response from Gemini."
        exit 1
    fi
done


COMMIT_MESSAGE=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text' |
    sed 's/^```//; s/```$//' |
    sed 's/^[ \t]*//; s/[ \t]*$//' |
    head -n 1
)

if [ -z "$COMMIT_MESSAGE" ]; then
    echo "Error: Failed to parse a valid commit message from the AI response."
    echo "Raw Response: $RESPONSE"
    exit 1
fi

echo "Generated Message: $COMMIT_MESSAGE"
echo "Committing..."

git commit -m "$COMMIT_MESSAGE"

echo "Commit successful!"
