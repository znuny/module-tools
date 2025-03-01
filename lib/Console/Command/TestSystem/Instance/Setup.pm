# --
# Copyright (C) 2001-2021 OTRS AG, https://otrs.com/
# Copyright (C) 2012 Znuny GmbH, https://znuny.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Console::Command::TestSystem::Instance::Setup;

use strict;
use warnings;

use Cwd;
use DBI;
use File::Find;
use File::Spec ();

use Path::Tiny qw(path);

use Console::Command::Module::File::Link;
use Console::Command::TestSystem::Database::Install;
use Console::Command::TestSystem::Database::Fill;

use parent qw(Console::BaseCommand);

=head1 NAME

Console::Command::TestSystem::Instance::Setup - Console command to setup and configure an Znuny test instance

=head1 DESCRIPTION

Configure settings, Database and Apache of a testing Znuny instance

=cut

sub Configure {
    my ( $Self, %Param ) = @_;

    $Self->Description('Set up a testing Znuny instance.');
    $Self->AddOption(
        Name        => 'framework-directory',
        Description => "Specify a base framework directory to set it up.",
        Required    => 1,
        HasValue    => 1,
        ValueRegex  => qr/.*/smx,
    );
    $Self->AddOption(
        Name        => 'database-type',
        Description => 'Specify database backend to use (Mysql, Postgresql or Oracle). Default: Mysql',
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr{^(mysql|postgresql|oracle)$}ismx,
    );
    $Self->AddOption(
        Name        => 'fred-directory',
        Description => "Specify directory of the Znuny module Fred.",
        Required    => 0,
        HasValue    => 1,
        ValueRegex  => qr/.*/smx,
    );

    return;
}

sub PreRun {
    my ($Self) = @_;

    my $FrameworkDirectory = File::Spec->rel2abs( $Self->GetOption('framework-directory') );

    my @Directories = ($FrameworkDirectory);

    my $FredDirectory = $Self->GetOption('fred-directory');
    if ($FredDirectory) {
        $FredDirectory = File::Spec->rel2abs($FredDirectory);
    }

    if ($FredDirectory) {
        push @Directories, $FredDirectory;
    }

    for my $Directory (@Directories) {
        if ( !-e $Directory ) {
            die "$Directory does not exist";
        }
        if ( !-d $Directory ) {
            die "$Directory is not a directory";
        }
    }

    if ( !-e ( $FrameworkDirectory . '/RELEASE' ) ) {
        die "$FrameworkDirectory does not seem to be an Znuny framework directory";
    }

    if ($FredDirectory) {
        if ( !-e $FredDirectory . '/Fred.sopm' ) {
            die "$FrameworkDirectory does not seem to be a Fred module directory";
        }
    }

    return;
}

sub Run {
    my ($Self) = @_;

    my $FrameworkDirectory = File::Spec->rel2abs( $Self->GetOption('framework-directory') );
    my $DatabaseType       = ucfirst( $Self->GetOption('database-type') || 'Mysql' );

    my $FredDirectory = $Self->GetOption('fred-directory');
    if ($FredDirectory) {
        $FredDirectory = File::Spec->rel2abs($FredDirectory);
    }

    # Remove possible slash at the end.
    $FrameworkDirectory =~ s{ / \z }{}xms;

    # Get Znuny major version number.
    my $ReleaseString = `cat $FrameworkDirectory/RELEASE`;
    my $MajorVersion  = '';
    if ( $ReleaseString =~ m{ VERSION \s+ = \s+ (\d+) .* \z }xms ) {
        $MajorVersion = $1;

        $Self->Print("\n<yellow>Installing testsystem for Znuny version $MajorVersion.</yellow>\n\n");
    }

    my %Config = %{ $Self->{Config}->{TestSystem} || {} };

    $Config{PermissionsUser}  //= $Config{PermissionsOTRSUser};
    $Config{PermissionsGroup} //= $Config{PermissionsOTRSGroup};

    if ( $MajorVersion >= 7 ) {
        $Config{ProductName}   = 'Znuny';
        $Config{ProductNameLC} = 'znuny';
    }
    else {
        $Config{ProductName}   = 'OTRS';
        $Config{ProductNameLC} = 'otrs';
    }

    # Define some maintenance commands.
    if ( $MajorVersion >= 5 ) {
        $Config{RebuildConfigCommand}
            = "sudo -u $Config{PermissionsUser} $FrameworkDirectory/bin/$Config{ProductNameLC}.Console.pl Maint::Config::Rebuild";
        $Config{DeleteCacheCommand}
            = "sudo -u $Config{PermissionsUser} $FrameworkDirectory/bin/$Config{ProductNameLC}.Console.pl Maint::Cache::Delete";
    }
    else {
        $Config{RebuildConfigCommand}
            = "sudo -u $Config{PermissionsUser} perl $FrameworkDirectory/bin/$Config{ProductNameLC}.RebuildConfig.pl";
        $Config{DeleteCacheCommand}
            = "sudo -u $Config{PermissionsUser} perl $FrameworkDirectory/bin/$Config{ProductNameLC}.DeleteCache.pl";
    }

    my $SystemName = $FrameworkDirectory;
    $SystemName =~ s{$Config{EnvironmentRoot}}{}xmsg;
    $SystemName =~ s{/}{}xmsg;

    # Determine a string that is used for database user name, database name and database password.
    my $DatabaseSystemName = $SystemName;
    $DatabaseSystemName =~ s{-}{_}xmsg;     # replace - by _ (hyphens not allowed in database name)
    $DatabaseSystemName =~ s{\.}{_}xmsg;    # replace . by _ (hyphens not allowed in database name)
    $DatabaseSystemName = substr( $DatabaseSystemName, 0, 16 );    # shorten the string (mysql requirement)

    # Copy WebApp.conf file.
    my $WebAppConfFile     = $FrameworkDirectory . '/Kernel/WebApp.conf';
    my $WebAppConfDistFile = $FrameworkDirectory . '/Kernel/WebApp.conf.dist';
    if ( -e $WebAppConfDistFile ) {

        $Self->Print("\n  <yellow>Copying WebApp.conf...</yellow>\n");

        my $WebAppConfStr = $Self->ReadFile($WebAppConfDistFile);

        my $Success = $Self->WriteFile( $WebAppConfFile, $WebAppConfStr );
        if ( !$Success ) {
            return $Self->ExitCodeError();
        }
    }

    # Edit Config.pm.
    $Self->Print("\n  <yellow>Editing and copying Config.pm...</yellow>\n");
    {
        if ( !-e ( $FrameworkDirectory . '/Kernel/Config.pm.dist' ) ) {
            $Self->PrintError("/Kernel/Config.pm.dist cannot be opened\n");
            return $Self->ExitCodeError();
        }

        my $ConfigStr = $Self->ReadFile( $FrameworkDirectory . '/Kernel/Config.pm.dist' );
        $ConfigStr =~ s{/opt/$Config{ProductNameLC}}{$FrameworkDirectory}xmsg;

        if ( $DatabaseType eq 'Mysql' ) {
            $ConfigStr =~ s{(\$Self->\{DatabaseHost\} =) '127.0.0.1';}{$1 '$Config{DatabaseHostMysql}';}msg
                if $Config{DatabaseHostMysql};
            $ConfigStr =~ s{(\$Self->\{DatabaseUser\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseUserNameMysql}';}msg
                if $Config{DatabaseUserNameMysql};
            $ConfigStr =~ s{(\$Self->\{DatabasePw\} =) 'some-pass';}{$1 '$Config{DatabasePasswordMysql}';}msg
                if $Config{DatabasePasswordMysql};
            $ConfigStr =~ s{(\$Self->\{Database\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseTableMysql}';}msg
                if $Config{DatabaseTableMysql};

        }
        elsif ( $DatabaseType eq 'Postgresql' ) {
            $ConfigStr =~ s{(\$Self->\{DatabaseHost\} =) '127.0.0.1';}{$1 '$Config{DatabaseHostPostgresql}';}msg
                if $Config{DatabaseHostPostgresql};
            $ConfigStr =~ s{(\$Self->\{DatabaseUser\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseUserNamePostgresql}';}msg
                if $Config{DatabaseUserNamePostgresql};
            $ConfigStr =~ s{(\$Self->\{DatabasePw\} =) 'some-pass';}{$1 '$Config{DatabasePasswordPostgresql}';}msg
                if $Config{DatabasePasswordPostgresql};
            $ConfigStr =~ s{(\$Self->\{Database\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseTablePostgresql}';}msg
                if $Config{DatabaseTablePostgresql};

            $ConfigStr
                =~ s{^#(    \$Self->\{DatabaseDSN\} = "DBI:Pg:dbname=\$Self->\{Database\};host=\$Self->\{DatabaseHost\};";)$}{$1}msg;
        }
        elsif ( $DatabaseType eq 'Oracle' ) {
            $ConfigStr =~ s{(\$Self->\{DatabaseHost\} =) '127.0.0.1';}{$1 '$Config{DatabaseHostOracle}';}msg
                if $Config{DatabaseHostOracle};
            $ConfigStr =~ s{(\$Self->\{DatabaseUser\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseUserNameOracle}';}msg
                if $Config{DatabaseUserNameOracle};
            $ConfigStr =~ s{(\$Self->\{DatabasePw\} =) 'some-pass';}{$1 '$Config{DatabasePasswordOracle}';}msg
                if $Config{DatabasePasswordOracle};
            $ConfigStr =~ s{(\$Self->\{Database\} =) '$Config{ProductNameLC}';}{$1 '$Config{DatabaseTableOracle}';}msg
                if $Config{DatabaseTableOracle};

            $ConfigStr
                =~ s{^\#(    \$Self->\{DatabaseDSN\} = "DBI:Oracle:\/\/\$Self->\{DatabaseHost\}:1521\/\$Self->\{Database\}";)$}{$1}msg;
            $ConfigStr
                =~ s{^\#    \$ENV\{ORACLE_HOME\}     = '/path/to/your/oracle';$}{    \$ENV{ORACLE_HOME}     = "$Config{DatabaseHomeOracle}";}msg;
            $ConfigStr =~ s{^\#(    \$ENV\{NLS_DATE_FORMAT\} = 'YYYY-MM-DD HH24:MI:SS';)$}{$1}msg;
            $ConfigStr =~ s{^\#(    \$ENV\{NLS_LANG\}        = 'AMERICAN_AMERICA.AL32UTF8';)$}{$1}msg;
        }

        $ConfigStr =~ s{('$Config{ProductNameLC}'|'some-pass')}{'$DatabaseSystemName'}xmsg;

        # Inject some more data.
        my $ConfigInjectStr = <<"EOD";

        \$Self->{'SecureMode'}          = 1;
        \$Self->{'SystemID'}            = '54';
        \$Self->{'SessionName'}         = '$SystemName';
        \$Self->{'ProductName'}         = '$SystemName';
        \$Self->{'ScriptAlias'}         = '$SystemName/';
        \$Self->{'Frontend::WebPath'}   = '/$SystemName-web/';
        \$Self->{'CheckEmailAddresses'} = 0;
        \$Self->{'CheckMXRecord'}       = 0;
        \$Self->{'Organization'}        = '';
        \$Self->{'LogModule'}           = 'Kernel::System::Log::File';
        \$Self->{'LogModule::LogFile'}  = '$Config{EnvironmentRoot}$SystemName/var/log/$Config{ProductNameLC}.log';
        \$Self->{'FQDN'}                = 'localhost';
        \$Self->{'DefaultLanguage'}     = 'de';
        \$Self->{'DefaultCharset'}      = 'utf-8';
        \$Self->{'AdminEmail'}          = 'root\@localhost';
        \$Self->{'Package::Timeout'}    = '120';
        \$Self->{'SendmailModule'}      = 'Kernel::System::Email::DoNotSendEmail';
        \$Self->{'WebMaxFileUpload'}    = 104857600;

        # Fred
        \$Self->{'Fred::BackgroundColor'} = '#006ea5';
        \$Self->{'Fred::SystemName'}      = '$SystemName';
        \$Self->{'Fred::ConsoleOpacity'}  = '0.7';
        \$Self->{'Fred::ConsoleWidth'}    = '30%';

        # Misc
        \$Self->{'Loader::Enabled::CSS'}  = 0;
        \$Self->{'Loader::Enabled::JS'}   = 0;

        \$Self->{'Frontend::TemplateCache'} = 0;

        # Selenium
        \$Self->{'SeleniumTestsConfig'} = {
            remote_server_addr  => 'localhost',
            port                => '4444',
            browser_name        => 'firefox',
            platform            => 'ANY',
            is_wd3              => 1, # web driver v3
            extra_capabilities  => {
                marionette => '',
            },
            # window_height => 1200,    # optional, default 1000
            # window_width  => 1600,    # optional, default 1200
        };
EOD

        # Use defined config injection instead.
        if ( $Config{ConfigInject} ) {
            $Config{ConfigInject} =~ s/\\\$/{DollarSign}/g;
            $Config{ConfigInject} =~ s/(\$\w+(\{\w+\})?)/$1/eeg;
            $Config{ConfigInject} =~ s/\{DollarSign\}/\$/g;
            $ConfigInjectStr = $Config{ConfigInject};
            print "    Overriding default configuration...\n    Done.\n";
        }

        $ConfigStr =~ s{\# \s* \$Self->\{CheckMXRecord\} \s* = \s* 0;}{$ConfigInjectStr}xms;

        # Comment out ScriptAlias and Frontend::WebPath so the default can be used.
        if ( -e $WebAppConfDistFile ) {

            $ConfigStr
                =~ s{(\$Self->\{'ScriptAlias'\} \s+ = \s+ ') [^']+ (';)}{# $1${SystemName}/$Config{ProductNameLC}/$2}xms;
            $ConfigStr =~ s{(\$Self->\{'Frontend::WebPath'\} \s+ = \s+ ') [^']+ (';)}{# $1/${SystemName}/htdocs/$2}xms;
        }

        my $Success = $Self->WriteFile( $FrameworkDirectory . '/Kernel/Config.pm', $ConfigStr );

        if ( !$Success ) {
            return $Self->ExitCodeError();
        }
    }

    # Check apache config.
    if ( !-e ( $FrameworkDirectory . '/scripts/apache2-httpd.include.conf' ) ) {
        $Self->PrintError("/scripts/apache2-httpd.include.conf cannot be opened\n");
        return $Self->ExitCodeError();
    }

    # Copy apache config file.
    my $ApacheConfigFile = "$Config{ApacheCFGDir}$SystemName.conf";
    $Self->System(
        "sudo cp -p $FrameworkDirectory/scripts/apache2-httpd.include.conf $ApacheConfigFile"
    );

    # Copy apache mod perl file.
    my $ApacheModPerlFile = "$Config{ApacheCFGDir}$SystemName.apache2-perl-startup.pl";
    if ( -e "$FrameworkDirectory/scripts/apache2-perl-startup.pl" ) {
        my $ApacheModPerlFile = "$Config{ApacheCFGDir}$SystemName.apache2-perl-startup.pl";
        $Self->System(
            "sudo cp -p $FrameworkDirectory/scripts/apache2-perl-startup.pl $ApacheModPerlFile"
        );

        $Self->Print("\n  <yellow>Editing Apache config...</yellow>\n");
        {
            my $ApacheConfigStr = $Self->ReadFile($ApacheConfigFile);
            $ApacheConfigStr
                =~ s{Perlrequire \s+ /opt/$Config{ProductNameLC}/scripts/apache2-perl-startup\.pl}{Perlrequire $ApacheModPerlFile}xms;
            $ApacheConfigStr =~ s{/opt/$Config{ProductNameLC}}{$FrameworkDirectory}xmsg;
            $ApacheConfigStr =~ s{ /$Config{ProductNameLC}/}{ /$SystemName/}msg;
            $ApacheConfigStr
                =~ s{$Config{EnvironmentRoot}/$Config{ProductNameLC}/}{$Config{EnvironmentRoot}/$SystemName/}xmsg;
            $ApacheConfigStr =~ s{/$Config{ProductNameLC}-web/}{/$SystemName-web/}xmsg;
            $ApacheConfigStr =~ s{<IfModule \s* mod_perl.c>}{<IfModule mod_perlOFF.c>}xmsg;
            $ApacheConfigStr =~ s{<Location \s+ /$Config{ProductNameLC}>}{<Location /$SystemName>}xms;

            my $Success = $Self->WriteFile( $ApacheConfigFile, $ApacheConfigStr );
            if ( !$Success ) {
                return $Self->ExitCodeError();
            }
        }

        $Self->Print("\n  <yellow>Editing Apache mod perl config...</yellow>\n");

        if ( -e $ApacheModPerlFile ) {

            my $ApacheModPerlConfigStr = $Self->ReadFile($ApacheModPerlFile);

            # Set correct path.
            $ApacheModPerlConfigStr =~ s{/opt/$Config{ProductNameLC}}{$FrameworkDirectory}xmsg;

            # Enable lines for MySQL.
            if ( $DatabaseType eq 'Mysql' ) {
                $ApacheModPerlConfigStr =~ s{^#(use DBD::mysql \(\);)$}{$1}msg;
                $ApacheModPerlConfigStr =~ s{^#(use Kernel::System::DB::mysql;)$}{$1}msg;
            }

            # Enable lines for PostgreSQL.
            elsif ( $DatabaseType eq 'Postgresql' ) {
                $ApacheModPerlConfigStr =~ s{^#(use DBD::Pg \(\);)$}{$1}msg;
                $ApacheModPerlConfigStr =~ s{^#(use Kernel::System::DB::postgresql;)$}{$1}msg;
            }

            # Enable lines for Oracle.
            elsif ( $DatabaseType eq 'Oracle' ) {
                $ApacheModPerlConfigStr
                    =~ s{^(\$ENV\{MOD_PERL\}.*?;)$}{$1\n\n\$ENV{ORACLE_HOME}     = "$Config{DatabaseHomeOracle}";\n\$ENV{NLS_DATE_FORMAT} = "YYYY-MM-DD HH24:MI:SS";\n\$ENV{NLS_LANG}        = "AMERICAN_AMERICA.AL32UTF8";}msg;
                $ApacheModPerlConfigStr =~ s{^#(use DBD::Oracle \(\);)$}{$1}msg;
                $ApacheModPerlConfigStr =~ s{^#(use Kernel::System::DB::oracle;)$}{$1}msg;
            }

            my $Success = $Self->WriteFile( $ApacheModPerlFile, $ApacheModPerlConfigStr );
            if ( !$Success ) {
                return $Self->ExitCodeError();
            }
        }

        # Restart apache.
        $Self->Print("\n  <yellow>Restarting apache...</yellow>\n");
        $Self->System("sudo $Config{ApacheRestartCommand}");
    }

    my $DSN;
    my @DBIParam;

    if ( $DatabaseType eq 'Mysql' ) {
        $DSN = 'DBI:mysql:';
    }
    elsif ( $DatabaseType eq 'Postgresql' ) {
        $DSN = "DBI:Pg:;host=$Config{DatabaseHostPostgresql}";
    }
    elsif ( $DatabaseType eq 'Oracle' ) {
        $DSN = "DBI:Oracle://$Config{DatabaseHostOracle}:1521/XE";
        ## nofilter(TidyAll::Plugin::Znuny::Perl::Require)
        require DBD::Oracle;    ## no critic
        push @DBIParam, {
            ora_session_mode => $DBD::Oracle::ORA_SYSDBA,    ## no critic
        };
        $ENV{ORACLE_HOME} = "$Config{DatabaseHomeOracle}";    ## no critic
    }

    my $DBH = DBI->connect(
        $DSN,
        $Config{"DatabaseUserName$DatabaseType"},
        $Config{"DatabasePassword$DatabaseType"},
        @DBIParam,
    );

    # Install database.
    $Self->Print("\n  <yellow>Creating Database...</yellow>\n");
    {
        if ( $DatabaseType eq 'Mysql' ) {
            $DBH->do("DROP DATABASE IF EXISTS $DatabaseSystemName");

            my $Charset = 'utf8mb4';
            if ( $MajorVersion < 8 ) {
                $Charset = 'utf8';
            }

            $DBH->do("CREATE DATABASE $DatabaseSystemName charset $Charset");
            $DBH->do("use $DatabaseSystemName");
        }
        elsif ( $DatabaseType eq 'Postgresql' ) {
            $DBH->do("DROP DATABASE IF EXISTS $DatabaseSystemName");
            $DBH->do("CREATE DATABASE $DatabaseSystemName");
        }
    }

    $Self->Print("\n  <yellow>Creating database user and privileges...\n</yellow>");
    {
        if ( $DatabaseType eq 'Mysql' ) {

            # Get MySQL version to avoid issues with MySQL 8.
            my $SQL = $DBH->prepare(
                "SELECT CONCAT( IF (INSTR( VERSION(),'MariaDB'),'MariaDB ','MySQL '), SUBSTRING_INDEX(VERSION(),'-',1))"
            );
            my $Res = $SQL->execute();

            my @Row = $SQL->fetchrow_array();

            my $Version = $Row[0];

            # Special handling for MySQL 8, as the default caching_sha2_password can only be used
            # over secure connections. Older mysql versions don't support IDENTIFIED WITH ... yet.
            $DBH->do("DROP USER IF EXISTS $DatabaseSystemName\@localhost");
            if ( $Version =~ /^MySQL (\d{1,3})\.(\d{1,3}).*/ && $1 >= 8 ) {
                $DBH->do(
                    "CREATE USER $DatabaseSystemName\@localhost IDENTIFIED WITH mysql_native_password BY '$DatabaseSystemName';"
                );
            }
            else {
                $DBH->do(
                    "CREATE USER $DatabaseSystemName\@localhost IDENTIFIED BY '$DatabaseSystemName';"
                );
            }

            $DBH->do(
                "GRANT ALL PRIVILEGES ON $DatabaseSystemName.* TO $DatabaseSystemName\@localhost;"
            );
            $DBH->do('FLUSH PRIVILEGES');
        }
        elsif ( $DatabaseType eq 'Postgresql' ) {
            $DBH->do("CREATE USER $DatabaseSystemName WITH PASSWORD '$DatabaseSystemName'");
            $DBH->do("GRANT ALL PRIVILEGES ON DATABASE $DatabaseSystemName TO $DatabaseSystemName");
        }
        elsif ( $DatabaseType eq 'Oracle' ) {
            $DBH->do("ALTER system SET processes=150 scope=spfile");
            $DBH->do("DROP USER $DatabaseSystemName CASCADE");
            $DBH->do("CREATE USER $DatabaseSystemName IDENTIFIED BY $DatabaseSystemName");
            $DBH->do("GRANT ALL PRIVILEGES TO $DatabaseSystemName");
        }
    }

    $Self->Print("\n  <yellow>Creating database schema...\n</yellow>");
    $Self->ExecuteCommand(
        Module => 'Console::Command::TestSystem::Database::Install',
        Params => [ '--framework-directory', $FrameworkDirectory ],
    );

    # Make sure we've got the correct rights set (e.g. in case you've downloaded the files as root).
    $Self->System("sudo chown -R $Config{PermissionsUser}:$Config{PermissionsGroup} $FrameworkDirectory");

    # Link fred module.
    if ($FredDirectory) {
        $Self->Print("\n  <yellow>Linking Fred module into $SystemName...</yellow>\n");
        $Self->ExecuteCommand(
            Module => 'Console::Command::Module::File::Link',
            Params => [ $FredDirectory, $FrameworkDirectory ],
        );
    }

    # Setting permissions.
    $Self->Print("\n  <yellow>Setting permissions...</yellow>\n");
    $Self->_SetPermissions(
        MajorVersion       => $MajorVersion,
        FrameworkDirectory => $FrameworkDirectory,
        Config             => \%Config,
    );

    # Deleting Cache.
    $Self->Print("\n  <yellow>Deleting cache...</yellow>\n");
    $Self->System( $Config{DeleteCacheCommand} );

    # Rebuild Config.
    $Self->Print("\n  <yellow>Rebuilding config...</yellow>\n");
    $Self->System( $Config{RebuildConfigCommand} );

    # Inject test data.
    $Self->Print("\n  <yellow>Injecting some test data...</yellow>\n");
    $Self->ExecuteCommand(
        Module => 'Console::Command::TestSystem::Database::Fill',
        Params => [ '--framework-directory', $FrameworkDirectory ],
    );

    # Setting permissions.
    $Self->Print("\n  <yellow>Setting permissions again (just to be sure)...</yellow>\n");
    $Self->_SetPermissions(
        MajorVersion       => $MajorVersion,
        FrameworkDirectory => $FrameworkDirectory,
        Config             => \%Config,
    );

    if ( $MajorVersion >= 7 ) {
        $Self->Print(
            "\n  <yellow>Start the development webserver with bin/$Config{ProductNameLC}.Console.pl Dev::Tools::WebServer</yellow>\n"
        );
        $Self->Print(
            "\n  <yellow>You can access the external interface with http://localhost:3001/external</yellow>\n"
        );
        $Self->Print(
            "\n  <yellow>You can access the agent interface with http://localhost:3000/$Config{ProductNameLC}/index.pl</yellow>\n"
        );
    }

    $Self->Print("\n<green>Done.</green>\n");
    return $Self->ExitCodeOk();
}

sub ReadFile {
    my ( $Self, $Path ) = @_;

    if ( !-e $Path ) {
        $Self->PrintError("Could find $Path");
    }
    if ( !-r $Path ) {
        $Self->PrintError("Couldn't open file $Path!");
    }

    my $Content = path($Path)->slurp_raw();
    return $Content;
}

sub WriteFile {
    my ( $Self, $Path, $Content ) = @_;

    my $FileHandle;

    if ( !open( $FileHandle, '>' . $Path ) ) {    ## no critic
        $Self->PrintError("Couldn't open $Path $!");
        return '';
    }
    print $FileHandle $Content;
    close $FileHandle;

    return 1;
}

sub System {
    my ( $Self, $Command ) = @_;

    my $Output = `$Command`;

    if ($Output) {
        $Output =~ s{^}{    }mg;
        $Self->Print($Output);
    }

    return 1;
}

sub ExecuteCommand {
    my ( $Self, %Param ) = @_;

    my $Output;
    {

        # Localize the standard error, everything will be restored after the block.
        local *STDERR;
        local *STDOUT;

        # Redirect the standard error and output to a variable.
        open STDERR, ">>", \$Output;
        open STDOUT, ">>", \$Output;

        my $ModuleObject = $Param{Module}->new();

        # Allow running as root, if parent command has been allowed to do so.
        if ( $Self->{AllowRoot} ) {
            unshift @{ $Param{Params} }, '--allow-root';
        }

        $ModuleObject->Execute( @{ $Param{Params} } );
    }

    $Output =~ s{^}{    }mg;
    $Self->Print($Output);

    return 1;
}

sub _SetPermissions {
    my ( $Self, %Param ) = @_;

    if ( $Param{MajorVersion} >= 7 ) {
        $Self->System(
            "sudo perl $Param{FrameworkDirectory}/bin/$Param{Config}->{ProductNameLC}.SetPermissions.pl --znuny-user=$Param{Config}->{PermissionsUser} --web-group=$Param{Config}->{PermissionsWebGroup} --admin-group=$Param{Config}->{PermissionsAdminGroup} $Param{FrameworkDirectory}"
        );
    }
    elsif ( $Param{MajorVersion} >= 5 ) {
        $Self->System(
            "sudo perl $Param{FrameworkDirectory}/bin/$Param{Config}->{ProductNameLC}.SetPermissions.pl --otrs-user=$Param{Config}->{PermissionsUser} --web-group=$Param{Config}->{PermissionsWebGroup} --admin-group=$Param{Config}->{PermissionsAdminGroup} $Param{FrameworkDirectory}"
        );
    }
    else {
        $Self->System(
            "sudo perl $Param{FrameworkDirectory}/bin/$Param{Config}->{ProductNameLC}.SetPermissions.pl --otrs-user=$Param{Config}->{PermissionsUser} --web-user=$Param{Config}->{PermissionsWebUser} --otrs-group=$Param{Config}->{PermissionsGroup} --web-group=$Param{Config}->{PermissionsWebGroup} --not-root $Param{FrameworkDirectory}"
        );
    }

    return 1;
}

1;
