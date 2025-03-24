#!/usr/bin/env perl
use 5.38.0;
use experimental qw(class try builtin);

use FindBin;
use local::lib "$FindBin::Bin/../local";

use Perl::Critic;
use Perl::Tidy;
use IO::Handle;

# Set stdout and stderr to be unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Protocol constants
my $PROTOCOL_VERSION = "2024-11-05";
my $SERVER_NAME      = "perl-validation";
my $SERVER_VERSION   = "1.0.0";

class Logger {
    field $file :param = $ENV{LOG_FILE};

    ADJUST {
        if ($file) {
            open STDERR, ">>", $file or die "Failed to open log file: $!";
        }
    }

    method log($message) {
        say STDERR "[MCP Server] $message";
    }
}

class Config {
    field $critic_severity :param :reader   = $ENV{CRITIC_SEVERITY} // 'gentle';
    field $critic_theme :param :reader      = $ENV{CRITIC_THEME}    // 'core';
    field $execution_timeout :param :reader = $ENV{EXECUTION_TIMEOUT} // 5;
    field $max_code_size :param :reader     = $ENV{MAX_CODE_SIZE}     // 50_000;
}

class MCPServer {
    use File::Temp qw(tempfile);
    use JSON::PP   qw(encode_json decode_json);
    use builtin    qw(true false);

    field $config :param;
    field $critic;
    field $logger = Logger->new();
    field $buffer = '';

    ADJUST {
        # Initialize Perl::Critic
        $critic = Perl::Critic->new(
            -severity => $config->critic_severity,
            -theme    => $config->critic_theme
        );
    }

    method run {
        $logger->log("Starting Perl Validation MCP server (STDIO version)");
        $logger->log("Server ready. Waiting for input...");

        # Process input stream
        while ( my $line = <STDIN> ) {
            $buffer .= $line;
            $self->process_buffer();
        }

        $logger->log("Server shutting down...");
    }

    method process_buffer {

        # Process line-by-line (each message is on a separate line)
        while ( $buffer =~ s/^(.*)\n// ) {
            my $line = $1;
            next unless $line =~ /\S/;    # Skip empty lines

            $logger->log("Received message: $line");

            try {
                my $message = decode_json($line);
                $self->handle_message($message);
            }
            catch ($e) {
                $logger->log("Parse error: $e");
                $self->send_error( -32700, "Parse error", undef );
            }
        }
    }

    method handle_message($message) {

        # Validate JSON-RPC version
        if ( !exists $message->{jsonrpc} || $message->{jsonrpc} ne "2.0" ) {
            $self->send_error( -32600, "Invalid Request", $message->{id} );
            return;
        }

        # Handle request
        if ( exists $message->{method} ) {
            $self->handle_request($message);
        }

        # We're not expecting responses in this simple server
        elsif ( exists $message->{result} || exists $message->{error} ) {
            $logger->log("Received response/error message (not handling)");
        }

        # Invalid message
        else {
            $logger->log("Invalid message format");
            $self->send_error( -32600, "Invalid Request", $message->{id} );
        }
    }

    method handle_request($request) {
        my $method = $request->{method};
        $logger->log("Handling request method: $method");

        if ( $method eq "initialize" ) {
            $self->handle_initialize($request);
        }
        elsif ( $method eq "tools/list" ) {
            $self->handle_list_tools($request);
        }
        elsif ( $method eq "tools/call" ) {
            $self->handle_call_tool($request);
        }
        elsif ( $method eq "prompts/list" ) {
            $self->handle_list_prompts($request);
        }
        elsif ( $method eq "prompts/get" ) {
            $self->handle_get_prompt($request);
        }
        elsif ( $method eq "shutdown" ) {
            $self->handle_shutdown($request);
        }
        elsif ( $method eq "exit" ) {
            $logger->log("Received exit notification");
            exit(0);
        }
        else {
            $logger->log("Method not found: $method");
            $self->send_error( -32601, "Method not found: $method",
                $request->{id} );
        }
    }

    method handle_initialize($request) {
        $logger->log("Handling initialize request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                protocolVersion => $PROTOCOL_VERSION,
                serverInfo      => {
                    name    => $SERVER_NAME,
                    version => $SERVER_VERSION
                },
                capabilities => {
                    tools   => {},
                    prompts => {}
                }
            }
        };

        $self->send_message($response);

        # Send initialized notification after successful initialization
        my $notification = {
            jsonrpc => "2.0",
            method  => "initialized",
            params  => {}
        };

        $self->send_message($notification);
    }

    method handle_list_tools($request) {
        $logger->log("Handling tools/list request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                tools => [
                    {
                        name        => "check_syntax",
                        description => "Check Perl code for syntax errors",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                code => {
                                    type        => "string",
                                    description => "The Perl code to check"
                                }
                            },
                            required => ["code"]
                        }
                    },
                    {
                        name        => "run_critic",
                        description => "Analyze Perl code with Perl::Critic",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                code => {
                                    type        => "string",
                                    description => "The Perl code to analyze"
                                },
                                severity => {
                                    type        => "string",
                                    description => "Critic severity level",
                                    enum        => [
                                        "gentle", "stern", "harsh", "cruel",
                                        "brutal"
                                    ],
                                    default => "gentle"
                                }
                            },
                            required => ["code"]
                        }
                    },
                    {
                        name        => "format_code",
                        description => "Format Perl code using Perl::Tidy",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                code => {
                                    type        => "string",
                                    description => "The Perl code to format"
                                },
                                perltidyrc => {
                                    type        => "string",
                                    description => "PerlTidy options",
                                    required    => 0
                                }
                            },
                            required => ["code"]
                        }
                    },
                    {
                        name        => "run_test",
                        description => "Run Perl code with optional input",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                code => {
                                    type        => "string",
                                    description => "The Perl code to run"
                                },
                                input => {
                                    type        => "string",
                                    description => "Input to provide (STDIN)",
                                    required    => 0
                                }
                            },
                            required => ["code"]
                        }
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method handle_call_tool($request) {
        $logger->log("Handling tools/call request");

        my $tool_name = $request->{params}{name};
        my $args      = $request->{params}{arguments};

        $logger->log( "Tool: $tool_name, Arguments: " . encode_json($args) );

        # Validate tool exists and code size
        if ( !$tool_name || !$args || !$args->{code} ) {
            $self->send_error( -32602,
                "Invalid params: missing tool name or code",
                $request->{id} );
            return;
        }

        # Check code size limit
        if ( length( $args->{code} ) > $config->max_code_size ) {
            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    isError => JSON::PP::true,
                    content => [
                        {
                            type => "text",
                            text => "Code exceeds maximum size of "
                              . $config->max_code_size
                              . " bytes"
                        }
                    ]
                }
            };
            $self->send_message($response);
            return;
        }

        # Execute appropriate tool
        if ( $tool_name eq "check_syntax" ) {
            $self->execute_check_syntax( $request, $args );
        }
        elsif ( $tool_name eq "run_critic" ) {
            $self->execute_run_critic( $request, $args );
        }
        elsif ( $tool_name eq "format_code" ) {
            $self->execute_format_code( $request, $args );
        }
        elsif ( $tool_name eq "run_test" ) {
            $self->execute_run_test( $request, $args );
        }
        else {
            $self->send_error( -32601, "Tool not found: $tool_name",
                $request->{id} );
        }
    }

    method execute_check_syntax( $request, $args ) {
        my $code = $args->{code};

        # Create a temporary file
        my ( $fh, $filename ) = tempfile( SUFFIX => '.pl' );
        print $fh $code;
        close $fh;

        # Run perl -c on the file
        my $output    = `perl -c $filename 2>&1`;
        my $exit_code = $? >> 8;

        unlink $filename;

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => $exit_code != 0 ? JSON::PP::true : JSON::PP::false,
                content => [
                    {
                        type => "text",
                        text => $output
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method execute_run_critic( $request, $args ) {
        my $code     = $args->{code};
        my $severity = $args->{severity} // $config->critic_severity;

        # Set critic severity for this run if provided
        my $temp_critic = $critic;
        if ( defined $severity && $severity ne $config->critic_severity ) {
            $temp_critic = Perl::Critic->new(
                -severity => $severity,
                -theme    => $critic->theme()
            );
        }

        # Create a temporary file
        my ( $fh, $filename ) = tempfile( SUFFIX => '.pl' );
        print $fh $code;
        close $fh;

        # Run Perl::Critic
        my @violations = $temp_critic->critique($filename);

        unlink $filename;

        # Format the results
        my $output = "Perl::Critic Results:\n\n";
        if (@violations) {
            $output .= "Found " . scalar(@violations) . " violations:\n\n";
            foreach my $violation (@violations) {
                $output .= "- "
                  . $violation->severity() . ": "
                  . $violation->description() . "\n";
                $output .=
                    "  Line "
                  . $violation->line_number()
                  . ", Column "
                  . $violation->column_number() . "\n";
                $output .= "  Policy: " . $violation->policy() . "\n";
                $output .= "\n";
            }
        }
        else {
            $output .= "No violations found.";
        }

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                  isError => scalar(@violations) > 0
                ? JSON::PP::true
                : JSON::PP::false,
                content => [
                    {
                        type => "text",
                        text => $output
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method execute_format_code( $request, $args ) {
        my $code       = $args->{code};
        my $perltidyrc = $args->{perltidyrc} // '';

        my $formatted_code;
        my $stderr_output;

        # Format the code
        Perl::Tidy::perltidy(
            source      => \$code,
            destination => \$formatted_code,
            stderr      => \$stderr_output,
            perltidyrc  => \$perltidyrc
        );

        # Check for errors
        if ($stderr_output) {
            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    isError => JSON::PP::true,
                    content => [
                        {
                            type => "text",
                            text => "Perl::Tidy Error:\n$stderr_output"
                        }
                    ]
                }
            };
            $self->send_message($response);
            return;
        }

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => JSON::PP::false,
                content => [
                    {
                        type => "text",
                        text => $formatted_code
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method execute_run_test( $request, $args ) {
        my $code  = $args->{code};
        my $input = $args->{input} // '';

        # Create a temporary file for the code
        my ( $fh, $filename ) = tempfile( SUFFIX => '.pl' );
        print $fh $code;
        close $fh;

        # Create input file if needed
        my $input_filename;
        if ($input) {
            my ( $input_fh, $temp_input ) = tempfile();
            print $input_fh $input;
            close $input_fh;
            $input_filename = $temp_input;
        }

        # Run with timeout
        my $cmd =
          "perl $filename" . ( $input_filename ? " < $input_filename" : "" );
        my $output;
        my $exit_code;

        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm $config->execution_timeout;
            $output    = `$cmd 2>&1`;
            $exit_code = $? >> 8;
            alarm 0;
        };

        # Clean up
        unlink $filename;
        unlink $input_filename if defined $input_filename;

        # Handle timeout
        if ( $@ =~ /timeout/ ) {
            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    isError => JSON::PP::true,
                    content => [
                        {
                            type => "text",
                            text => "Execution timed out after "
                              . $config->execution_timeout
                              . " seconds"
                        }
                    ]
                }
            };
            $self->send_message($response);
            return;
        }

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => $exit_code ? JSON::PP::true : JSON::PP::false,
                content => [
                    {
                        type => "text",
                        text => $output || "No output produced."
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method handle_list_prompts($request) {
        $logger->log("Handling prompts/list request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                prompts => [
                    {
                        name        => "perl_module_template",
                        description => "Generate a basic Perl module template",
                        arguments   => [
                            {
                                name        => "module_name",
                                description =>
                                  "The name of the module (e.g., My::Module)",
                                required => true,
                            },
                            {
                                name        => "description",
                                description =>
                                  "Short description of the module",
                                required => false,
                            }
                        ]
                    },
                    {
                        name        => "perl_script_template",
                        description => "Generate a basic Perl script template",
                        arguments   => [
                            {
                                name        => "script_name",
                                description => "The name of the script",
                                required    => true,
                            },
                            {
                                name        => "description",
                                description =>
                                  "Short description of the script",
                                required => false,
                            }
                        ]
                    },
                    {
                        name        => "perl_class_template",
                        description =>
"Generate a modern Perl class template using native class syntax",
                        arguments => [
                            {
                                name        => "class_name",
                                description => "The name of the class",
                                required    => true,
                            },
                            {
                                name        => "fields",
                                description =>
                                  "Comma-separated list of class fields",
                                required => false,
                            }
                        ]
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method handle_get_prompt($request) {
        $logger->log("Handling prompts/get request");

        my $prompt_name = $request->{params}{name};
        my $args        = $request->{params}{arguments} // {};

        $logger->log(
            "Prompt: $prompt_name, Arguments: " . encode_json($args) );

        if ( $prompt_name eq "perl_module_template" ) {
            my $module_name = $args->{module_name} // 'My::Module';
            my $description = $args->{description} // 'A Perl module';

            my $messages = [
                {
                    role    => "user",
                    content => {
                        type => "text",
                        text =>
"Please create a Perl module template for '$module_name' with the following description: '$description'.\n\nInclude standard sections for imports, constants, subroutines, and documentation."
                    }
                }
            ];

            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    description => "Perl module template for $module_name",
                    messages    => $messages
                }
            };

            $self->send_message($response);
        }
        elsif ( $prompt_name eq "perl_script_template" ) {
            my $script_name = $args->{script_name} // 'script.pl';
            my $description = $args->{description} // 'A Perl script';

            my $messages = [
                {
                    role    => "user",
                    content => {
                        type => "text",
                        text =>
"Please create a Perl script template for '$script_name' with the following description: '$description'.\n\nInclude standard sections for imports, usage, command-line processing, and error handling."
                    }
                }
            ];

            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    description => "Perl script template for $script_name",
                    messages    => $messages
                }
            };

            $self->send_message($response);
        }
        elsif ( $prompt_name eq "perl_class_template" ) {
            my $class_name = $args->{class_name} // 'MyClass';
            my $fields     = $args->{fields}     // '';

            my $messages = [
                {
                    role    => "user",
                    content => {
                        type => "text",
                        text =>
"Please create a modern Perl class template for '$class_name' with the following fields: '$fields'.\n\nUse Perl 5.38.0 native class syntax with field declarations, ADJUST blocks, and methods."
                    }
                }
            ];

            my $response = {
                jsonrpc => "2.0",
                id      => $request->{id},
                result  => {
                    description =>
"Perl class template for $class_name using native class syntax",
                    messages => $messages
                }
            };

            $self->send_message($response);
        }
        else {
            $self->send_error( -32601, "Prompt not found: $prompt_name",
                $request->{id} );
        }
    }

    method handle_shutdown($request) {
        $logger->log("Handling shutdown request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {}
        };

        $self->send_message($response);

        # Exit after sending response
        exit(0);
    }

    # Send a JSON-RPC message
    method send_message($message) {
        my $message_json = encode_json($message);
        $logger->log("Sending message: $message_json");
        say $message_json;
    }

    # Send a JSON-RPC error
    method send_error( $code, $message, $id ) {
        $logger->log("Sending error: $message (code: $code)");

        # Ensure id is never null to avoid issues with Claude Desktop
        my $error = {
            jsonrpc => "2.0",
            id      => defined($id) ? 0 + $id : 0,
            error   => {
                code    => $code,
                message => $message
            }
        };

        $self->send_message($error);
    }

    # Optional: send a logging notification to the client
    method send_log_notification( $level, $message ) {
        my $notification = {
            jsonrpc => "2.0",
            method  => "notifications/logging/message",
            params  => {
                level => $level,    # "debug", "info", "warning", "error"
                data  => $message
            }
        };

        $self->send_message($notification);
    }
}

# Create and run server
my $config = Config->new();
my $server = MCPServer->new( config => $config );
$server->run();

__END__

=head1 NAME

perl-validation-server.pl - MCP server for Perl code validation

=head1 DESCRIPTION

An MCP (Model Context Protocol) server that provides tools for Perl code validation,
including syntax checking, critic analysis, formatting, and code execution.

=head1 USAGE

  ./perl-validation-server.pl [options]

  Environment variables:
    CRITIC_SEVERITY    - Perl::Critic severity level (default: gentle)
    CRITIC_THEME       - Perl::Critic theme (default: core)
    EXECUTION_TIMEOUT  - Timeout for code execution in seconds (default: 5)
    MAX_CODE_SIZE      - Maximum code size in bytes (default: 50000)
    LOG_FILE           - Optional log file path

=head1 INTEGRATION WITH CLAUDE DESKTOP

To integrate with Claude Desktop:

1. Edit the Claude Desktop configuration file:
   ~/Library/Application Support/Claude/claude_desktop_config.json (Mac)
   %AppData%\Claude\claude_desktop_config.json (Windows)

2. Add your server configuration:
   {
     "mcpServers": {
       "perl-validation": {
         "command": "perl",
         "args": [
           "/path/to/perl-validation-server.pl"
         ]
       }
     }
   }

3. Restart Claude Desktop

=head1 AVAILABLE TOOLS

This server provides four tools:

1. check_syntax - Check Perl code for syntax errors
2. run_critic - Analyze Perl code with Perl::Critic
3. format_code - Format Perl code using Perl::Tidy
4. run_test - Run Perl code with optional input

=head1 AVAILABLE PROMPTS

This server provides three prompts:

1. perl_module_template - Generate a basic Perl module template
2. perl_script_template - Generate a basic Perl script template
3. perl_class_template - Generate a modern Perl class template using native class syntax

=cut
