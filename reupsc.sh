#!/bin/bash

repository_update() {
    local update_output
    local arch_warning
    local repo_domain
    local repo_file

    echo "Starting repository update check..."

    # Remove root check since sudo is handled by calling function

    # Use timeout command with apt-get
    update_output=$(script -q -c "sudo apt-get update" /dev/null 2>&1) || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "❌ apt-get update timed out after ${TIMEOUT} seconds"
        else
            echo "❌ Failed to run apt-get update (exit code: $exit_code)"
        fi
        return 1
    }
    echo "✅ Initial update check completed"

    echo "Debug: Update output:"
    echo "$update_output"

    # Capture the architecture warning line.
    arch_warning=$(echo "$update_output" | grep -i "N: Skipping acquire.*binary-i386.*doesn't support architecture 'i386'")
    if [ -z "$arch_warning" ]; then
        echo "✅ Repository configuration is correct - no architecture issues found"
        return 0
    fi

    echo "⚠️ Found architecture warning:"
    echo "$arch_warning"

    # Extract the repository domain using a regex.
    # The regex captures text after "repository 'https://" until the next slash or square bracket.
    repo_domain=$(echo "$arch_warning" | grep -oP "(?<=repository 'https:\/\/)[^\[\]\/]+" | tr -d '[]')
    if [ -z "$repo_domain" ]; then
        echo "Could not extract repository domain."
        return 1
    fi

    echo "Extracted repository domain: $repo_domain"

    # Locate the repository file that contains the domain and clean the output
    repo_file=$(grep -Rl --exclude="*.bak" "^deb.*$repo_domain" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null |
        head -n1 |
        sed 's/[[:space:]]*$//')
    if [ -f "$repo_file" ]; then
        echo "✅ Found repository file: $repo_file"
        # Backup with timestamp
        local backup_file="${repo_file}.bak.$(date +%Y%m%d_%H%M%S)"
        sudo cp "$repo_file" "$backup_file" || {
            echo "❌ Failed to create backup file"
            return 1
        }
        echo "✅ Backup created: $backup_file"

        # Modify with error checking
        if ! sudo sed -i.tmp '/^\s*deb / { /arch=amd64/! s|^deb\s\+\(\[[^]]*\]\)\?\s\+|deb [arch=amd64] | }' "$repo_file"; then
            echo "❌ Failed to modify repository file"
            sudo cp "$backup_file" "$repo_file" && sudo chmod --reference="$backup_file" "$repo_file"
            return 1
        fi
        rm -f "${repo_file}.tmp"

        # Verify file modification
        if ! grep -q "^\s*deb\s*\[arch=amd64\]" "$repo_file"; then
            echo "❌ Repository modification verification failed"
            sudo cp "$backup_file" "$repo_file" && sudo chmod --reference="$backup_file" "$repo_file"
            return 1
        fi
        rm -f "${backup_file}"
        echo "✅ Repository configuration updated successfully"
        echo "Current configuration in $repo_file:"
        cat "$repo_file"
    else
        echo "❌ Could not find repository file for domain: $repo_domain"
        return 1
    fi

    if dpkg --print-foreign-architectures | grep -q "i386"; then
        if ! dpkg -l | grep -q "i386"; then
            echo "⚠️ Removing i386 architecture..."
            sudo dpkg --remove-architecture i386
            echo "✅ i386 architecture removed successfully"
        else
            echo "⚠️ Cannot remove i386: Installed packages depend on it"
        fi
    fi

    # Re-run apt-get update to verify the fix.
    echo "Running final update check..."
    if ! sudo apt-get update; then
        echo "❌ Failed to update package lists after configuration change"
        echo "ℹ️ Restoring backup is recommended using: sudo cp '${backup_file}' '$repo_file'"
        return 1
    fi
    echo "✅ Repository update completed successfully"
}
