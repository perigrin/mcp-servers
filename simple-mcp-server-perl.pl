#!/usr/bin/env perl
use 5.38.0;
use JSON::PP;
use IO::Handle;
use Log::Log4perl::Tiny qw(:easy);

# Make sure stdout is unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Protocol constants
my $PROTOCOL_VERSION = "2024-11-05";
my $SERVER_NAME      = "simple-calculator";
my $SERVER_VERSION   = "1.0.0";

# For message IDs
my $message_id = 1;

# Buffer for input processing
my $buffer = '';

# Process the buffer to extract complete JSON-RPC messages
sub process_buffer {

    # Process line-by-line (each message is on a separate line)
    while ( $buffer =~ s/^(.*)\n// ) {
        my $line = $1;
        next unless $line =~ /\S/;    # Skip empty lines

        eval {
            my $message = decode_json($line);
            handle_message($message);
        };
        if ($@) {
            log_message("Parse error: $@");
            send_error( -32700, "Parse error", undef );
        }
    }
}

# Handle incoming messages
sub handle_message ($message) {

    # Validate JSON-RPC version
    if ( !exists $message->{jsonrpc} || $message->{jsonrpc} ne "2.0" ) {
        send_error( -32600, "Invalid Request", $message->{id} );
        return;
    }

    # Handle request
    if ( exists $message->{method} ) {
        handle_request($message);
    }

    # We're not expecting responses in this simple server
    elsif ( exists $message->{result} || exists $message->{error} ) {

        # Would handle responses here in a more complex implementation
    }

    # Invalid message
    else {
        send_error( -32600, "Invalid Request", $message->{id} );
    }
}

# Handle incoming requests
sub handle_request ($request) {

    my $method = $request->{method};

    if ( $method eq "initialize" ) {
        handle_initialize($request);
    }
    elsif ( $method eq "tools/list" ) {
        handle_list_tools($request);
    }
    elsif ( $method eq "tools/call" ) {
        handle_call_tool($request);
    }
    else {
        send_error( -32601, "Method not found: $method", $request->{id} );
    }
}

# Handle initialize request
sub handle_initialize ($request) {

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
                tools => {}
            }
        }
    };

    send_message($response);

    # Send initialized notification after successful initialization
    my $notification = {
        jsonrpc => "2.0",
        method  => "initialized",
        params  => {}
    };

    send_message($notification);
}

# Handle tools/list request
sub handle_list_tools ($request) {

    my $response = {
        jsonrpc => "2.0",
        id      => $request->{id},
        result  => {
            tools => [
                {
                    name        => "calculate",
                    description => "Perform basic mathematical operations",
                    inputSchema => {
                        type       => "object",
                        properties => {
                            operation => {
                                type => "string",
                                enum =>
                                  [ "add", "subtract", "multiply", "divide" ],
                                description =>
                                  "Mathematical operation to perform"
                            },
                            a => {
                                type        => "number",
                                description => "First operand"
                            },
                            b => {
                                type        => "number",
                                description => "Second operand"
                            }
                        },
                        required => [ "operation", "a", "b" ]
                    }
                }
            ]
        }
    };

    send_message($response);
}

# Handle tools/call request
sub handle_call_tool ($request) {

    my $name = $request->{params}{name};
    my $args = $request->{params}{arguments};

    if ( $name ne "calculate" ) {
        send_error( -32601, "Tool not found: $name", $request->{id} );
        return;
    }

    my $result;
    my $is_error = 0;

    eval {
        my $operation = $args->{operation};
        my $a         = $args->{a};
        my $b         = $args->{b};

        if ( $operation eq "add" ) {
            $result = $a + $b;
        }
        elsif ( $operation eq "subtract" ) {
            $result = $a - $b;
        }
        elsif ( $operation eq "multiply" ) {
            $result = $a * $b;
        }
        elsif ( $operation eq "divide" ) {
            if ( $b == 0 ) {
                die "Division by zero";
            }
            $result = $a / $b;
        }
        else {
            die "Unknown operation: $operation";
        }
    };

    if ($@) {

        # Handle error case
        my $error_message = $@;
        $error_message =~ s/ at .*? line \d+.*//;    # Remove Perl line info

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => JSON::PP::true,
                content => [
                    {
                        type => "text",
                        text => "Error: $error_message"
                    }
                ]
            }
        };

        send_message($response);
    }
    else {
        # Handle success case
        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => JSON::PP::false,
                content => [
                    {
                        type => "text",
                        text => "$result"
                    }
                ]
            }
        };

        send_message($response);
    }
}

# Send a JSON-RPC message
sub send_message ($message) {

    my $message_json = encode_json($message);
    print "$message_json\n";
}

# Send a JSON-RPC error
sub send_error ( $code, $message, $id ) {

    my $error = {
        jsonrpc => "2.0",
        id      => 0 + $id,
        error   => {
            code    => $code,
            message => $message
        }
    };

    send_message($error);
}

# Set format to include [MCP Server] prefix
Log::Log4perl->easy_init(
    {
        layout => '[MCP Server] %m%n',
        level  => $ENV{DEBUG} ? $DEBUG : $INFO,
        ( $ENV{LOG_FILE} ? ( file => $ENV{LOG_FILE} ) : () )
    }
);

# Log a message to stderr for debugging using Log::Log4perl::Tiny
sub log_message ( $message, $level = 'info' ) {
    get_logger()->$level($message);
}

# Optional: send a logging notification to the client
sub send_log_notification ( $level, $message ) {

    my $notification = {
        jsonrpc => "2.0",
        method  => "notifications/logging/message",
        params  => {
            level => $level,    # "debug", "info", "warning", "error"
            data  => $message
        }
    };

    send_message($notification);
}

# Log startup information
log_message("Simple MCP Calculator Server started");
log_message("Supports protocol version: $PROTOCOL_VERSION");
log_message("Ready to receive messages...");

# Main loop - read from stdin
while ( my $line = <STDIN> ) {
    $buffer .= $line;
    process_buffer();
}
