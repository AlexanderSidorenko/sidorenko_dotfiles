# My personal bash aliases that are shared across all workstations I use

alias gb='git branch'
alias gm='git merge'
alias gba='git branch -a'
alias gc='git commit -v'
alias gd='git diff'
alias gdc='git diff --cached'
alias gl='git pull'
alias gp='git push'
alias gst='git status .'
alias ga='git add'
alias gco='git checkout'
alias gg='git log --graph --pretty=oneline --abbrev-commit'
alias gr='grep --color -n -R --include *.cpp --include *.h --include *.c . -e '

cf()
{
    (test -z $1 || test -z $2) && echo -e "Create a tarball with a nice progress bar\nUsage: cf TARBALL_NAME FILES" ||
    (
    echo -e "Calculating total size..."
    _TotalSize=`du --total --summarize  --bytes ${*:2} | tail -1 | cut --fields 1`
    echo -e "Total size is $_TotalSize bytes"
    echo -e "Creating tarball..."
    tar caf - ${*:2} | pv --progress --eta --rate --bytes --size $_TotalSize > $1
    )
}

xf()
{
    (test -z $1) && echo -e "Extract a tarball with a nice progress bar\nUsage: xf TARBALL_NAME [PATH]" ||
    (
    echo -e "Extracting tarball..."
    if [ -z "$2" ]
    then
        pv $1 | tar xaf - 
    else
        pv $1 | tar xaf - -C $2
    fi
    )
}

function cheat()
{
    curl cht.sh/$1
}
