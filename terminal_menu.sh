#!/usr/bin/env bash
# terminal_menu.sh
# Interactive terminal launcher for all project scripts.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

    local path rel
    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("shell")
    done < <(find \
        "$REPO_ROOT/build" \
        "$REPO_ROOT/core" \
        "$REPO_ROOT/magisk-module" \
        "$REPO_ROOT/recovery-zip" \
        -type f -name "*.sh" | sort)

    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("python")
    done < <(find "$REPO_ROOT/pipeline" -maxdepth 1 -type f -name "*.py" | sort)
}

print_menu() {
    echo
    echo "hands-on-metal terminal menu"
    echo "Repository: $REPO_ROOT"
    echo
    local i
    for i in "${!SCRIPT_LABELS[@]}"; do
        printf "%2d) [%s] %s\n" "$((i + 1))" "${SCRIPT_TYPES[$i]}" "${SCRIPT_LABELS[$i]}"
    done
    echo
    echo " r) refresh script list"
    echo " q) quit"
}

run_selected() {
    local idx="$1"
    local script="${SCRIPT_PATHS[$idx]}"
    local kind="${SCRIPT_TYPES[$idx]}"
    local rel="${SCRIPT_LABELS[$idx]}"
    local args_array=()

    echo
    echo "Selected: $rel"
    read -r -a args_array -p "Arguments (optional): "

    echo
    echo "Running..."
    (
        cd "$REPO_ROOT" || exit 1
        if [ "$kind" = "python" ]; then
            if [ "${#args_array[@]}" -gt 0 ]; then
                python3 "$script" "${args_array[@]}"
            else
                python3 "$script"
            fi
        else
            if [ "${#args_array[@]}" -gt 0 ]; then
                bash "$script" "${args_array[@]}"
            else
                bash "$script"
            fi
        fi
    )
    local rc=$?
    echo
    echo "Exit code: $rc"
    echo
}

main() {
    if [ ! -d "$REPO_ROOT/pipeline" ]; then
        echo "Error: run this script from the repository root." >&2
        exit 1
    fi

    build_script_index

    if [ "${#SCRIPT_LABELS[@]}" -eq 0 ]; then
        echo "No scripts found." >&2
        exit 1
    fi

    while true; do
        print_menu
        read -r -p "Choose an option: " choice

        case "$choice" in
            q|Q)
                echo "Bye."
                exit 0
                ;;
            r|R)
                build_script_index
                continue
                ;;
            ''|*[!0-9]*)
                echo "Invalid choice."
                ;;
            *)
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#SCRIPT_LABELS[@]}" ]; then
                    echo "Invalid choice."
                else
                    run_selected "$((choice - 1))"
                fi
                ;;
        esac
    done
}

main "$@"
