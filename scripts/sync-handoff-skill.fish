#!/usr/bin/env fish

set script_dir (path dirname (status filename))
source "$script_dir/lib/storage.fish"

function fail
    printf 'error: %s\n' "$argv" >&2
    exit 1
end

function require_command --argument-names command_name
    if not type -q "$command_name"
        fail "Missing required command: $command_name"
    end
end

for command_name in chmod cp diff mkdir mktemp mv rm rmdir
    require_command "$command_name"
end

set source_skill (path resolve -- "$script_dir/../skills/handoff")
if not set -q source_skill[1]; or not test -d "$source_skill"; or test -L "$source_skill"
    fail "Handoff skill source is unavailable: $script_dir/../skills/handoff"
end

set agents_home "$HOME/.agents"
set agents_skills_home "$agents_home/skills"
if test -L "$agents_home"; or test -L "$agents_skills_home"
    fail 'Global skill directories must not be symbolic links.'
end
if test -e "$agents_home"; and not test -d "$agents_home"
    fail "Global skills parent is not a directory: $agents_home"
end
if not test -e "$agents_home"
    command mkdir "$agents_home"
    or fail "Could not create global skills parent: $agents_home"
end
if test -e "$agents_skills_home"; and not test -d "$agents_skills_home"
    fail "Global skills path is not a directory: $agents_skills_home"
end
if not test -e "$agents_skills_home"
    command mkdir "$agents_skills_home"
    or fail "Could not create global skills path: $agents_skills_home"
end

set target_skill "$agents_skills_home/handoff"
if test -L "$target_skill"
    fail "Existing handoff skill must not be a symbolic link: $target_skill"
end
if test -e "$target_skill"; and not test -d "$target_skill"
    fail "Existing handoff skill is not a directory: $target_skill"
end
if test -d "$target_skill"; and diff -qr "$source_skill" "$target_skill" >/dev/null
    printf '%s\n' 'Global handoff skill is already current.'
    exit 0
end

set stage_parent (mktemp -d "$agents_skills_home/.handoff-skill-stage.XXXXXX")
if not set -q stage_parent[1]
    fail 'Could not create handoff skill staging directory.'
end
set staged_skill "$stage_parent/handoff"
command cp -R "$source_skill" "$staged_skill"
or begin
    command rm -rf "$stage_parent"
    fail 'Could not stage the handoff skill.'
end

if not test -d "$target_skill"
    command mv "$staged_skill" "$target_skill"
    or begin
        command rm -rf "$stage_parent"
        fail 'Could not publish the handoff skill.'
    end
    command rmdir "$stage_parent" 2>/dev/null
    printf '%s\n' "Installed global handoff skill: $target_skill"
    exit 0
end

set backup_root (pair_handoff_home)/handoff-skill-backups
command mkdir -p "$backup_root"
or begin
    command rm -rf "$stage_parent"
    fail "Could not create skill backup directory: $backup_root"
end
command chmod 700 "$backup_root"
or begin
    command rm -rf "$stage_parent"
    fail "Could not secure skill backup directory: $backup_root"
end
set backup_parent (mktemp -d "$backup_root/handoff.XXXXXX")
if not set -q backup_parent[1]
    command rm -rf "$stage_parent"
    fail 'Could not create handoff skill backup directory.'
end
set backup_skill "$backup_parent/handoff"

command mv "$target_skill" "$backup_skill"
or begin
    command rm -rf "$stage_parent"
    command rmdir "$backup_parent" 2>/dev/null
    fail 'Could not preserve the existing handoff skill.'
end
command mv "$staged_skill" "$target_skill"
or begin
    command mv "$backup_skill" "$target_skill" 2>/dev/null
    command rm -rf "$stage_parent"
    command rmdir "$backup_parent" 2>/dev/null
    fail 'Could not publish the refreshed handoff skill.'
end
command rmdir "$stage_parent" 2>/dev/null

printf '%s\n' "Refreshed global handoff skill: $target_skill"
printf '%s\n' "Previous skill backup: $backup_skill"
