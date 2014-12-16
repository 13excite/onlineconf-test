package MR::OnlineConf::Admin::PerlMemory;

use Mouse;

# External modules
use JSON::XS;
use Text::Glob;
use List::MoreUtils;
use Net::IP::CMatch;

# Internal modules
use MR::OnlineConf::Admin::Storage;
use MR::OnlineConf::Admin::PerlMemory::Parameter;

has log => (
    is  => 'ro',
    isa => 'Mojo::Log',
    required => 1,
);

has list => (
    is => 'ro',
    isa => 'ArrayRef',
    lazy => 1,
    default => sub {
        return MR::OnlineConf::Admin::Storage->select(qq[
            SELECT
                `ID`, `Name`, `Path`, `Deleted`, `Version`, `Value`, `ContentType`
            FROM
                `my_config_tree`
            WHERE NOT
                `Deleted`
            ORDER BY
                `Path`
        ]);
    }
);

has root => (
    is => 'ro',
    isa => 'MR::OnlineConf::Admin::PerlMemory::Parameter',
    lazy => 1,
    default => sub {
        return MR::OnlineConf::Admin::PerlMemory::Parameter->new(%{$_[0]->list->[0]});
    }
);

has host => (
    is => 'rw',
    isa => 'Str',
);

has addr => (
    is => 'rw',
    isa => 'ArrayRef',
);

has index => (
    is  => 'ro',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

has cases => (
    is => 'ro',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

has symlinks => (
    is => 'ro',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

has templates => (
    is => 'ro',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },
);

has JSONParser => (
    is => 'ro',
    isa => 'JSON::XS',
    lazy => 1,
    default => sub {
        return JSON::XS->new->utf8(0);
    }
);

sub BUILD {
    my ($self) = @_;
    my $list = $self->list;

    foreach my $item (@$list) {
        $self->put(
            MR::OnlineConf::Admin::PerlMemory::Parameter->new(%$item)
        );
    }
}

sub put {
    my ($self, $node) = @_;

    if ($node->Deleted) {
        return $self->delete($node);
    }

    if ($node->Path eq '/') {
        return 1;
    }

    # Update
    if (my $indexed = $self->index->{$node->Path}) {
        unless ($indexed->Version < $node->Version) {
            return 1;
        }

        $indexed->clear();

        $indexed->_Value($node->Value);
        $indexed->_Version($node->Version);
        $indexed->_ContentType($node->ContentType);

        return 1;
    } 

    # Create
    if (my $root = $self->root) {
        my @path = grep $_, split /\//, $node->Path;

        pop @path;

        while (my $name = shift @path) {
            unless ($root = $root->children->{$name}) {
                die sprintf "Failed to put parameter %s: no parent node found", $node->Path;
            }
        }

        $root->add_child($node);

        $self->index->{$node->Path} = $node;
        $self->cases->{$node->Path} = $node if $node->is_case;
        $self->symlinks->{$node->Path} = $node if $node->is_symlink;
        $self->templates->{$node->Path} = $node if $node->is_template;

        return 1;
    }

    die sprintf "Failed to put parameter %s: no root node found", $node->Path;
}

sub get {
    my ($self, $path) = @_;

    if (exists $self->index->{$path}) {
        my $indexed = $self->index->{$path};

        if ($indexed->is_symlink) {
            if (!$indexed->symlink_target) {
                $self->_resolve_symlink($indexed);
            }

            return $indexed->symlink_target;

        }

        return $indexed unless $indexed->is_symlink;
    }

    my $node = $self->root;
    my @path = grep $_, split /\//, $path;

    while (defined(my $name = shift @path)) {
        if ($node = $node->children->{$name}) {
            my %seen;

            while ($node->is_symlink) {
                my $ID = $node->ID;

                die "Recursion in symlink" if $seen{$ID};

                $seen{$ID} = 1;

                if (!$node->symlink_target && exists $self->{seen}) {
                    $self->_resolve_symlink($node);
                }

                $node = $node->symlink_target;

                return unless $node;
            }
        } else {
            return;
        }
    }

    return $node;
}

sub delete {
    my ($self, $param) = @_;
    my $node = $self->root;
    my @path = grep $_, split /\//, $param->path;

    delete $self->index->{$param->Path};

    while (defined(my $name = shift @path)) {
        if (my $child = $node->children->{$name}) {
            if (@path == 0) {
                delete $self->cases->{$child->Path};
                delete $self->symlinks->{$child->Path};
                delete $self->templates->{$child->Path};
                $node->delete_child($child);
                return 1;
            } else {
                $node = $child;
            }
        } else {
            return 0;
        }
    }

    return 0;
}

sub finalize {
    my ($self) = @_;

    $self->_resolve_cases();
    $self->_resolve_symlinks();
    $self->_resolve_templates();
}

sub serialize {
    my ($self) = @_;

    local $self->{seen_node} = {};

    return (
        join "\n", map {
            "$_->[0] $_->[1]"
        } sort {
            $a->[0] cmp $b->[0]
        } $self->_serialize(
            $self->root, ''
        )
    );
}

sub _serialize {
    my ($self, $node, $Path) = @_;
    my $children = $node->children;
    my @data;

    local $self->{seen_node}->{$node->ID} = 1;

    while (my ($name, $child) = each %$children) {
        next unless $child;
        next if $self->{seen_node}->{$child->ID};

        if ($child->is_symlink) {
            next unless $child = $self->get($child->value);
            next if $self->{seen_node}->{$child->ID};
        }

        if (defined (my $value = $child->value)) {
            if (ref $value) {
                push @data, [
                    "$Path/$name:JSON", eval {
                        $self->JSONParser->encode($value)
                    }
                ];
            } else {
                $value =~ s/\n/\\n/g;
                $value =~ s/\r/\\r/g;

                push @data, ["$Path/$name", $value];
            }
        }

        push @data, $self->_serialize($child, "$Path/$name");
    }

    return @data;
}

sub _resolve_cases {
    my ($self) = @_;
    my $host = $self->host;
    my $addr = $self->addr;
    my $cases = $self->cases;
    my $groups = $self->_which_groups();
    my $datacenter = $self->_which_datacenter();

    foreach my $case (values %$cases) {
        $case->host($host);
        $case->addr($addr);
        $case->groups($groups);
        $case->datacenter($datacenter);

        $case->clear_case_before_resolve();
        $case->resolve_case();

        if ($case->is_symlink) {
            local $self->{seen} = {};
            $case->clear_symlink_before_resolve();
            $self->_resolve_symlink($case);
        }

        if ($case->is_template) {
            $case->clear_template_before_resolve();
            $self->_resolve_template($case);
        }
    }
}

sub _which_groups {
    my ($self) = @_;
    my @groups;

    local $self->{seen} = {};

    if (my $groups = $self->get('/onlineconf/group')) {
        my $host = $self->host;
        my @all_groups = grep { $_ ne 'priority' } sort keys %{$groups->children};
        my @ordered_groups;

        if (my $priority = $self->get('/onlineconf/group/priority')) {
            if ($priority->value) {
                @ordered_groups = map {
                    $_ eq '*' ? @all_groups : $_
                } grep {
                    exists $groups->children->{$_}
                } split /\s*,\s*/, $priority->value;
            }
        }

        my @list = map {
            $_ => $groups->children->{$_}
        } List::MoreUtils::uniq(
            @ordered_groups, @all_groups
        );

        for (my $i = 0; $i <= $#list; $i += 2) {
            my $name = $list[$i];
            my $node = $list[$i+1];

            unless ($node = $self->get($node->Path)) {
                next;
            }

            if (my $glob = $node->value) {
                if (hostname_match_glob($glob, $host)) {
                    push @groups, $name;
                }
            }

            my $children = $node->children;

            foreach my $subname (sort keys %$children) {
                push @list, $name => $node->children->{$subname};
            }
        }
    }

    return [ List::MoreUtils::uniq @groups ];
}


sub _which_datacenter {
    my ($self) = @_;

    local $self->{seen} = {};

    if (my $datacenters = $self->get('/onlineconf/datacenter')) {
        my $children = $datacenters->children;
        foreach my $dc (values %$children) {
            my @masks = ref $dc->value eq 'ARRAY' ? @{$dc->value} : grep $_, split /(?:,|\s+)/, $dc->value;
            foreach my $addr (@{$self->addr}) {
                return $dc if Net::IP::CMatch::match_ip($addr, @masks);
            }
        }
    }

    return;
}

sub _resolve_symlinks {
    my ($self) = @_;
    my $symlinks = $self->symlinks;

    foreach my $symlink (values %$symlinks) {
        local $self->{seen} = {};
        $symlink->clear_symlink_before_resolve();
        $self->_resolve_symlink($symlink);
    }

    return;
}

sub _resolve_symlink {
    my ($self, $symlink) = @_;
    my $ID = $symlink->ID;

    if ($self->{seen}->{$ID}) {
        return;
    }

    $self->{seen}->{$ID} = 1;

    if (my $node = $self->get($symlink->value)) {
        $symlink->symlink_target($node);
    }

    return;
}

sub _resolve_templates {
    my ($self) = @_;
    my $host = $self->host;
    my $addr = $self->addr;
    my $templates = $self->templates;

    foreach my $template (values %$templates) {
        $template->host($host);
        $template->addr($addr);
        $template->clear_template_before_resolve();
        $self->_resolve_template($template);
    }

    return;
}

sub _resolve_template {
    my ($self, $template) = @_;
    my $value = $template->value;

    $value =~ s#\$\{(\/.*?)\}#
        my $replace = '';

        if (my $node = $self->get($1)) {
            $node->clear_value();
            $node->host($self->host);
            $node->addr($self->addr);
            $replace = $node->value;
        }

        $replace;
    #eg;

    $template->set_value($value);

    return;
}

my %glob_to_regex_cache;

sub hostname_match_glob {
    my $glob = shift;
    my $re;

    local $Text::Glob::strict_leading_dot = 0;
    local $Text::Glob::strict_wildcard_slash = 1;

    unless ($re = $glob_to_regex_cache{$glob}) {
        my $re_str = Text::Glob::glob_to_regex_string($glob);
        $re_str =~ s/\Q[^\/]\E/[^\\.]/g;
        $glob_to_regex_cache{$glob} = $re = qr/^$re_str$/;
    }

    return $_[0] =~ $re;
}

no Mouse;

__PACKAGE__->meta->make_immutable();

1;
