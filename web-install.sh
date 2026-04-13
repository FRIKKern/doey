#!/usr/bin/env bash
set -euo pipefail

# Doey — Web Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

REPO_URL="https://github.com/FRIKKern/doey.git"
# Persistent install location — never /tmp, so `doey update` and
# resolve_repo_dir() keep working after the installer exits.
CLONE_DIR="${DOEY_REPO_DIR:-$HOME/.local/share/doey-repo}"
mkdir -p "$(dirname "$CLONE_DIR")"

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

if [ -d "$CLONE_DIR/.git" ]; then
  echo "  Updating existing clone at $CLONE_DIR..."
  if git -C "$CLONE_DIR" fetch --quiet origin main && \
     git -C "$CLONE_DIR" reset --hard --quiet origin/main; then
    echo "  ✓ Repository updated"
  else
    echo "  ✗ Failed to update existing clone — remove $CLONE_DIR and retry."
    exit 1
  fi
else
  echo "  Cloning repository to $CLONE_DIR..."
  if git clone --quiet "$REPO_URL" "$CLONE_DIR"; then
    echo "  ✓ Repository cloned"
  else
    echo "  ✗ Failed to clone repository — check git and network access."
    exit 1
  fi
fi

echo ""
bash "$CLONE_DIR/install.sh"
