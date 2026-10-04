# Install-state policy shared by install.sh and verify.sh. Source this file; do not execute it.

install_state_allows_exchange() {
    [[ "${1:-unknown}" == "idle" ]]
}
