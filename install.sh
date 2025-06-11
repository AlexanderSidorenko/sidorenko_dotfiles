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
