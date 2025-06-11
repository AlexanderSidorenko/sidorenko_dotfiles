# Install my bashrc
echo "source ~/.sidorenko_dotfiles/bashrc" >> ~/.bashrc

# Install my zshrc
echo "source ~/.sidorenko_dotfiles/zshrc" >> ~/.zshrc

# Install .gitconfig
{
    echo ""
    echo "[include]"
    echo "    path = ~/.sidorenko_dotfiles/gitconfig.personal"
} >> "$HOME/.gitconfig"

safe_link() {
    local src="$1"
    local dest="$2"

    if [ -L "$dest" ]; then
        echo "✅ Symlink already exists: $dest → $(readlink "$dest")"
    elif [ -e "$dest" ]; then
        echo "❌ $dest exists and is not a symlink. Please back it up or remove it manually."
        return 1
    else
        mkdir -p "$(dirname "$dest")"
        ln -s "$src" "$dest"
        echo "🔗 Created symlink: $dest → $src"
    fi
}

safe_link "$HOME/.sidorenko_dotfiles/ranger" "$HOME/.config/ranger"
