# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright 2017 The Sympa Community. See the AUTHORS.md file at the top-level
# directory of this distribution and at
# <https://github.com/sympa-community/sympa.git>.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Request::Handler::move_list;

use strict;
use warnings;
use File::Copy qw();

use Sympa;
use Sympa::Admin;
use Conf;
use Sympa::Constants;
use Sympa::DatabaseManager;
use Sympa::List;
use Sympa::Log;
use Sympa::Regexps;
use Sympa::Tools::File;

use base qw(Sympa::Request::Handler);

my $log = Sympa::Log->instance;

use constant _action_regexp   => qr{reject|listmaster|do_it}i;
use constant _action_scenario => 'create_list';

# Old name: Sympa::Admin::rename_list().
sub _twist {
    $log->syslog('info', '',);
    my $self    = shift;
    my $request = shift;

    my $robot_id     = $request->{context};
    my $current_list = $request->{current_list};
    my $listname     = lc $request->{listname};
    my $mode         = $request->{mode};
    my $pending      = $request->{pending};
    my $notify       = $request->{notify};
    my $sender       = $request->{sender};

    die 'bug in logic. Ask developer'
        unless ref $current_list eq 'Sympa::List';

    # Check new listname syntax.
    my $listname_re = Sympa::Regexps::listname();
    unless ($listname =~ /^$listname_re$/i
        and length $listname <= Sympa::Constants::LIST_LEN()) {
        $log->syslog('err', 'Incorrect listname %s', $listname);
        $self->add_stash($request, 'user', 'incorrect_listname',
            {bad_listname => $listname});
        return undef;
    }

    # If list is included by another list, then it cannot be renamed.
    unless ($mode and $mode eq 'copy') {
        if ($current_list->is_included) {
            $log->syslog('err',
                'List %s is included by other list: cannot rename it',
                $current_list);
            $self->add_stash($request, 'user', 'cannot_rename_list',
                {reason => 'included'});
            return undef;
        }
    }

    # Check listname on SMTP server.
    # Do not test if listname did not change.
    my $res;
    unless ($current_list->{'name'} eq $listname) {
        $res = Sympa::Admin::list_check_smtp($listname, $robot_id);
        unless (defined $res) {
            $log->syslog('err', 'Can\'t check list %.128s on %.128s',
                $listname, $robot_id);
            $self->add_stash($request, 'intern');    #FIXME
            return undef;
        }
    }
    if ($res or $current_list->{'name'} eq $listname) {
        $log->syslog('err',
            'Could not rename list %s: new list %s on %s already exist',
            $current_list, $listname, $robot_id);
        $self->add_stash($request, 'user', 'list_already_exists',
            {new_listname => $listname});
        return undef;
    }

    my $regx = Conf::get_robot_conf($robot_id, 'list_check_regexp');
    if ($regx) {
        if ($listname =~ /^(\S+)-($regx)$/) {
            $log->syslog('err',
                'Incorrect listname %s matches one of service aliases',
                $listname);
            $self->add_stash($request, 'user', 'listname_matches_aliases',
                {new_listname => $listname});
            return undef;
        }
    }

    # Rename or create this list directory itself.
    my $new_dir;
    my $home = $Conf::Conf{'home'};
    my $base = $home . '/' . $robot_id;
    if (-d $base) {
        $new_dir = $base . '/' . $listname;
    } elsif ($robot_id eq $Conf::Conf{'domain'}) {
        # Default robot.
        $new_dir = $home . '/' . $listname;
    } else {
        $log->syslog('err', 'Unknown robot %s', $robot_id);
        $self->add_stash($request, 'user', 'unknown_robot',
            {new_robot => $robot_id});
        return undef;
    }

    if ($mode and $mode eq 'copy') {
        _copy($self, $request, $new_dir) or return undef;
    } else {
        _move($self, $request, $new_dir) or return undef;
    }

    my $list;
    unless ($list =
        Sympa::List->new($listname, $robot_id, {reload_config => 1})) {
        $log->syslog('err', 'Unable to load %s while renaming', $listname);
        $self->add_stash($request, 'intern');
        return undef;
    }

    if ($listname ne $request->{listname}) {
        $self->add_stash($request, 'notice', 'listname_lowercased');
    }

    if ($list->{'admin'}{'status'} eq 'open') {
        # Install new aliases.
        Sympa::Admin::install_aliases($list);

        $self->add_stash($request, 'notice', 'auto_aliases');
    } elsif ($list->{'admin'}{'status'} eq 'pending') {
        # Notify listmaster that creation list is moderated.
        Sympa::send_notify_to_listmaster(
            $list,
            'request_list_renaming',
            {   'new_listname' => $listname,
                'old_listname' => $current_list->{'name'},
                'email'        => $sender,
                'mode'         => $mode,
            }
        ) if $notify;

        $self->add_stash($request, 'notice', 'pending_list');
    }

    if ($mode and $mode eq 'copy') {
        $log->add_stat(
            robot     => $list->{'domain'},
            list      => $list->{'name'},
            operation => 'copy_list',
            mail      => $sender,
            client    => $self->{scenario_context}->{remote_addr},
        );
    }

    return 1;
}

sub _move {
    my $self    = shift;
    my $request = shift;
    my $new_dir = shift;

    my $robot_id     = $request->{context};
    my $listname     = $request->{listname};
    my $current_list = $request->{current_list};
    my $sender       = $request->{sender};
    my $pending      = $request->{pending};

    $current_list->savestats();

    # Remove aliases and dump subscribers.
    Sympa::Admin::remove_aliases($current_list);
    $current_list->_save_list_members_file(
        $current_list->{'dir'} . '/subscribers.closed.dump');

    # Set list status to pending if creation list is moderated.
    # Save config file for the new() later to reload it.
    $current_list->{'admin'}{'status'} = 'pending'
        if $pending;
    _modify_custom_subject($request, $current_list);
    $current_list->save_config($sender);

    # Start moving list
    unless (File::Copy::move($current_list->{'dir'}, $new_dir)) {
        $log->syslog(
            'err',
            'Unable to rename %s to %s: %m',
            $current_list->{'dir'}, $new_dir
        );
        $self->add_stash($request, 'intern');
        return undef;
    }

    # Rename archive.
    my $arc_dir = $current_list->get_archive_dir;
    my $new_arc_dir =
          Conf::get_robot_conf($robot_id, 'arc_path') . '/'
        . $listname . '@'
        . $robot_id;
    if (-d $arc_dir and $arc_dir ne $new_arc_dir) {
        unless (File::Copy::move($arc_dir, $new_arc_dir)) {
            $log->syslog('err', 'Unable to rename archive %s to %s',
                $arc_dir, $new_arc_dir);
            # continue even if there is some troubles with archives
            #$self->add_stash($request, 'intern');
            #return undef;
        }
    }

    # Rename bounces.
    my $bounce_dir = $current_list->get_bounce_dir;
    my $new_bounce_dir =
          Conf::get_robot_conf($robot_id, 'bounce_path') . '/'
        . $listname . '@'
        . $robot_id;
    if (-d $bounce_dir and $bounce_dir ne $new_bounce_dir) {
        unless (File::Copy::move($bounce_dir, $new_bounce_dir)) {
            $log->syslog('err', 'Unable to rename bounces from %s to %s',
                $bounce_dir, $new_bounce_dir);
        }
    }

    my $sdm = Sympa::DatabaseManager->instance;

    # If subscribtion are stored in database rewrite the database.
    unless (
        $sdm
        and $sdm->do_prepared_query(
            q{UPDATE subscriber_table
              SET list_subscriber = ?, robot_subscriber = ?
              WHERE list_subscriber = ? AND robot_subscriber = ?},
            $listname,               $robot_id,
            $current_list->{'name'}, $current_list->{'domain'}
        )
        and $sdm->do_prepared_query(
            q{UPDATE admin_table
              SET list_admin = ?, robot_admin = ?
              WHERE list_admin = ? AND robot_admin = ?},
            $listname,               $robot_id,
            $current_list->{'name'}, $current_list->{'domain'}
        )
        and $sdm->do_prepared_query(
            q{UPDATE list_table
              SET name_list = ?, robot_list = ?
              WHERE name_list = ? AND robot_list = ?},
            $listname,               $robot_id,
            $current_list->{'name'}, $current_list->{'domain'}
        )
        and $sdm->do_prepared_query(
            q{UPDATE inclusion_table
              SET target_inclusion = ?
              WHERE target_inclusion = ?},
            sprintf('%s@%s', $listname, $robot_id),
            $current_list->get_id
        )
        ) {
        $log->syslog('err',
            'Unable to rename list %s to %s@%s in the database',
            $current_list, $listname, $robot_id);
        return undef;
    }

    # Move stats.
    unless (
        $sdm
        and $sdm->do_prepared_query(
            q{UPDATE stat_table
              SET list_stat = ?, robot_stat = ?
              WHERE list_stat = ? AND robot_stat = ?},
            $listname,               $robot_id,
            $current_list->{'name'}, $current_list->{'domain'}
        )
        and $sdm->do_prepared_query(
            q{UPDATE stat_counter_table
              SET list_counter = ?, robot_counter = ?
              WHERE list_counter = ? AND robot_counter = ?},
            $listname,               $robot_id,
            $current_list->{'name'}, $current_list->{'domain'}
        )
        ) {
        $log->syslog('err',
            'Unable to transfer stats from list %s to list %s@%s',
            $current_list, $listname, $robot_id);
    }

    # Rename files in spools.
    my $current_listname = $current_list->{'name'};
    my $current_list_id  = $current_list->get_id;
    my $list_id          = $listname . '@' . $robot_id;

    ## Auth & Mod  spools
    foreach my $spool (
        'queueauth',      'queuemod',
        'queuetask',      'queuebounce',
        'queue',          'queueoutgoing',
        'queuesubscribe', 'queueautomatic',
        'queuedigest'
        ) {
        unless (opendir(DIR, $Conf::Conf{$spool})) {
            $log->syslog('err', 'Unable to open "%s" spool: %m',
                $Conf::Conf{$spool});
        }

        foreach my $file (sort readdir(DIR)) {
            next
                unless ($file =~ /^$current_listname\_/
                || $file =~ /^$current_listname/
                || $file =~ /^$current_listname\./
                || $file =~ /^$current_list_id\./
                || $file =~ /^\.$current_list_id\_/
                || $file =~ /^$current_list_id\_/
                || $file =~ /\.$current_listname$/);

            my $newfile = $file;
            if ($file =~ /^$current_listname\_/) {
                $newfile =~ s/^$current_listname\_/$listname\_/;
            } elsif ($file =~ /^$current_listname/) {
                $newfile =~ s/^$current_listname/$listname/;
            } elsif ($file =~ /^$current_listname\./) {
                $newfile =~ s/^$current_listname\./$listname\./;
            } elsif ($file =~ /^$current_list_id\./) {
                $newfile =~ s/^$current_list_id\./$list_id\./;
            } elsif ($file =~ /^$current_list_id\_/) {
                $newfile =~ s/^$current_list_id\_/$list_id\_/;
            } elsif ($file =~ /^\.$current_list_id\_/) {
                $newfile =~ s/^\.$current_list_id\_/\.$list_id\_/;
            } elsif ($file =~ /\.$current_listname$/) {
                $newfile =~ s/\.$current_listname$/\.$listname/;
            }

            ## Rename file
            unless (
                File::Copy::move(
                    $Conf::Conf{$spool} . '/' . $file,
                    $Conf::Conf{$spool} . '/' . $newfile
                )
                ) {
                $log->syslog(
                    'err',
                    'Unable to rename %s to %s: %m',
                    "$Conf::Conf{$spool}/$newfile",
                    "$Conf::Conf{$spool}/$newfile"
                );
                next;
            }
        }

        close DIR;
    }
    ## Digest spool
    if (-f "$Conf::Conf{'queuedigest'}/$current_listname") {
        unless (
            File::Copy::move(
                $Conf::Conf{'queuedigest'} . '/' . $current_listname,
                $Conf::Conf{'queuedigest'} . '/' . $listname
            )
            ) {
            $log->syslog(
                'err',
                'Unable to rename %s to %s: %m',
                "$Conf::Conf{'queuedigest'}/$current_listname",
                "$Conf::Conf{'queuedigest'}/$listname"
            );
            next;
        }
    } elsif (-f "$Conf::Conf{'queuedigest'}/$current_list_id") {
        unless (
            File::Copy::move(
                $Conf::Conf{'queuedigest'} . '/' . $current_list_id,
                $Conf::Conf{'queuedigest'} . '/' . $list_id
            )
            ) {
            $log->syslog(
                'err',
                'Unable to rename %s to %s: %m',
                $Conf::Conf{'queuedigest'} . '/' . $current_list_id,
                $Conf::Conf{'queuedigest'} . '/' . $list_id
            );
            next;
        }
    }

    return 1;
}

sub _copy {
    my $self    = shift;
    my $request = shift;
    my $new_dir = shift;

    my $robot_id     = $request->{context};
    my $listname     = $request->{listname};
    my $current_list = $request->{current_list};
    my $sender       = $request->{sender};
    my $pending      = $request->{pending};

    # If we are in 'copy' mode, create a new list.
    my $new_list;
    unless (
        $new_list = _clone_list_as_empty(
            $current_list, $listname, $robot_id, $sender, $new_dir
        )
        ) {
        $log->syslog('err', 'Unable to load %s while renaming', $listname);
        $self->add_stash($request, 'intern');
        return undef;
    }

    # Set list status to pending if creation list is moderated.
    # Save config file for the new() later to reload it.
    $new_list->{'admin'}{'status'} = 'pending'
        if $pending;
    _modify_custom_subject($request, $new_list);
    $new_list->save_config($sender);

    return 1;
}

# Old name: Sympa::Admin::clone_list_as_empty().
sub _clone_list_as_empty {
    $log->syslog('debug2', '(%s,%s,%s,%s,%s)', @_);
    my $current_list = shift;
    my $listname     = shift;
    my $robot_id     = shift;
    my $sender       = shift;
    my $new_dir      = shift;

    unless (mkdir $new_dir, 0775) {
        $log->syslog('err', 'Failed to create directory %s: %m', $new_dir);
        return undef;
    }
    chmod 0775, $new_dir;
    foreach my $subdir ('etc', 'web_tt2', 'mail_tt2', 'data_sources') {
        if (-d $new_dir . '/' . $subdir) {
            unless (
                Sympa::Tools::File::copy_dir(
                    $current_list->{'dir'} . '/' . $subdir,
                    $new_dir . '/' . $subdir
                )
                ) {
                $log->syslog(
                    'err',
                    'Failed to copy_directory %s: %m',
                    $new_dir . '/' . $subdir
                );
                return undef;
            }
        }
    }
    # copy mandatory files
    foreach my $file ('config') {
        unless (
            File::Copy::copy(
                $current_list->{'dir'} . '/' . $file,
                $new_dir . '/' . $file
            )
            ) {
            $log->syslog(
                'err',
                'Failed to copy %s: %m',
                $new_dir . '/' . $file
            );
            return undef;
        }
    }
    # copy optional files
    foreach my $file ('message.footer', 'message.header', 'info', 'homepage')
    {
        if (-f $current_list->{'dir'} . '/' . $file) {
            unless (
                File::Copy::copy(
                    $current_list->{'dir'} . '/' . $file,
                    $new_dir . '/' . $file
                )
                ) {
                $log->syslog(
                    'err',
                    'Failed to copy %s: %m',
                    $new_dir . '/' . $file
                );
                return undef;
            }
        }
    }

    my $new_list;
    # Now switch List object to new list, update some values.
    unless ($new_list =
        Sympa::List->new($listname, $robot_id, {'reload_config' => 1})) {
        $log->syslog('info', 'Unable to load %s while renamming', $listname);
        return undef;
    }
    $new_list->{'admin'}{'serial'} = 0;
    $new_list->{'admin'}{'creation'}{'email'} = $sender if ($sender);
    $new_list->{'admin'}{'creation'}{'date_epoch'} = time;
    $new_list->save_config($sender);
    return $new_list;
}

sub _modify_custom_subject {
    my $request  = shift;
    my $new_list = shift;

    return unless defined $new_list->{'admin'}{'custom_subject'};

    # Check custom_subject.
    my $custom_subject  = $new_list->{'admin'}{'custom_subject'};
    my $old_listname_re = $request->{current_list}->{'name'};
    $old_listname_re =~ s/([^\s\w\x80-\xFF])/\\$1/g;    # excape metachars
    my $listname = $request->{listname};

    $custom_subject =~ s/\b$old_listname_re\b/$listname/g;
    $new_list->{'admin'}{'custom_subject'} = $custom_subject;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Request::Handler::move_list - move_list request handler

=head1 DESCRIPTION

Renames a list or move a list to possiblly beyond another virtual host.

On copy mode, Clone a list config including customization, templates,
scenario config but without archives, subscribers and shared.

=head2 Attributes

See also L<Sympa::Request/"Attributes">.

=over

=item {context}

Context of request.  The robot the new list will belong to.

=item {current_list}

Source of moving or copying.  An instance of L<Sympa::List>.

=item {listname}

The name of the new list.

=item {mode}

I<Optional>.
If it is set and its value is C<'copy'>,
won't erase source list.

=back

=head1 SEE ALSO

L<Sympa::Request::Collection>,
L<Sympa::Request::Handler>,
L<Sympa::Spindle::ProcessRequest>.

=head1 HISTORY

L<Sympa::Request::Handler::move_list> appeared on Sympa 6.2.19b.

=cut
