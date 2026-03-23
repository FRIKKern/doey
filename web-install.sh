#!/usr/bin/env bash
set -euo pipefail

# Doey — Web Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

REPO_URL="https://github.com/FRIKKern/doey.git"
CLONE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/doey-install.XXXXXX")
trap 'rm -rf "$CLONE_DIR"' EXIT

cat << 'DOG'

            .
           ...      :-=++++==--:
               .-***=-:.   ..:=+#%*:
    .     :=----=.               .=%*=:
    ..   -=-                     .::. :#*:
      .+=    := .-+**+:        :#@%%@%- :*%=
      *+.    @.*@**@@@@#.      %@=  *@@= :*=
    :*:     .@=@=  *@@@@%      #@%+#@%#@  :-+
   .%++      #*@@#%@@#%@@      :@@@@@*+@  :%#
    %#       ==%@@@@@=+@+       :*%@@@#: :=*
   .@--     -+=.+%@@@@*:            :.:--:-.
   .@%#    ##*  ...:.:                 +=
    .-@- .#*.   . ..                   :%
      :+++%.:       .=.                 #+
          =**        .*=                :@.
       .   .@:+.       +#:               =%
            :*:+:--.   =+%*.              *+
                .- :-=:-+:+%=              #:
                           .*%-            .%.
                             :%#:        ...-#
                               =%*.   =#@%@@@@*
                                 =%+.-@@#=%@@@@-
                                   -#*@@@@@@@@@.
                                     .=#@@@@%+.

   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
   Let Doey do it for you

  ======================================

DOG

if ! command -v git &>/dev/null; then
  echo "  ✗ git is required but not installed."
  case "$(uname -s)" in
    Darwin) echo "    Install: brew install git" ;;
    Linux)  echo "    Install: sudo apt-get install -y git" ;;
    *)      echo "    Install git for your platform and re-run" ;;
  esac
  exit 1
fi

# Pre-flight: check for tmux so the user gets feedback early
if ! command -v tmux &>/dev/null; then
  echo "  ⚠ tmux is not installed (required by Doey)"
  case "$(uname -s)" in
    Darwin) echo "    The installer will offer to install it via Homebrew." ;;
    Linux)  echo "    The installer will offer to install it via apt." ;;
  esac
  echo ""
fi

echo "  Cloning repository..."
if git clone --depth 1 "$REPO_URL" "$CLONE_DIR"; then
  echo "  ✓ Repository cloned"
else
  echo "  ✗ Failed to clone repository — check git and network access."
  exit 1
fi

echo ""
bash "$CLONE_DIR/install.sh"
