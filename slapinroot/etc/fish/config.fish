set -l uid (id -u)
set -gx XDG_RUNTIME_DIR /run/user/$uid
if not test -d $XDG_RUNTIME_DIR
    mkdir -p $XDG_RUNTIME_DIR
    chown $uid:$uid $XDG_RUNTIME_DIR
    chmod 700 $XDG_RUNTIME_DIR
end
