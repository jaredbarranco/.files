function gitPushObsidian () {
        STARTDIR="$(pwd)"
        OBSIDIAN="/Users/jared/Documents/GitHub/obsidian-vault"
        USER="jaredbarranco"
        SUFFIX=".git"

        echo $STARTDIR

        cd $OBSIDIAN

        IS_REPO=$(git rev-parse --git-dir)
        CUR_REMOTE="$(git remote -v)"


        git add *
        git commit -a -m "$(date  +"%Y%m%d%H%M")"
        git push --all

        cd $STARTDIR
}