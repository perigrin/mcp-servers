#!/usr/bin/env perl
use 5.38.0;
use experimental qw(class try builtin);
use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::EventEmitter;
use Time::HiRes qw(time);

# Protocol constants
my $PROTOCOL_VERSION = "2024-11-05";
my $SERVER_NAME      = "sse-calculator";
my $SERVER_VERSION   = "1.0.0";

# For managing active connections
my %connections;
my $events             = Mojo::EventEmitter->new;
my $heartbeat_interval = 5;                         # seconds
my $debug              = $ENV{DEBUG} // 0;

# Configure logging
app->log->level( $debug ? 'debug' : 'info' );

# Set custom log format with timestamps
app->log->format(
    sub ( $time, $level, @lines ) {
        return
            "["
          . localtime(time)
          . "] [$$] [$level] "
          . join( "\n", @lines ) . "\n";
    }
);

# SSE endpoint - handles server-to-client communication
get '/sse' => sub ($c) {

    # Set up SSE headers
    $c->res->headers->content_type('text/event-stream');
    $c->res->headers->header( 'Cache-Control'               => 'no-cache' );
    $c->res->headers->header( 'Connection'                  => 'keep-alive' );
    $c->res->headers->header( 'Access-Control-Allow-Origin' => '*' );
    app->log->debug("SET HEADERS FOR SSE CONNECTION");

    # Set up connection
    my $conn_id = int( rand(1000000) );
    app->log->debug("New SSE connection: $conn_id");

    # Initial comment to establish connection
    $c->write(":\n");
    app->log->debug("SENT INITIAL COMMENT LINE");

    # Send connection ID using simple format expected by MCP Inspector
    $c->write("event: connectionId\ndata: $conn_id\n\n");
    app->log->debug("SENT CONNECTION ID EVENT");

    # Send endpoint event to tell client where to POST messages
    $c->write("event: endpoint\ndata: /messages?connection_id=$conn_id\n\n");
    app->log->debug("SENT ENDPOINT EVENT");

    # Store connection info
    $connections{$conn_id} = {
        controller      => $c,
        last_activity   => time(),
        heartbeat_count => 0,
    };

    # Send a debug message
    send_event( $conn_id, 'debug', { message => "Connection established" } );
    app->log->debug("SENT DEBUG MESSAGE");

    # Start heartbeat for this connection
    Mojo::IOLoop->recurring(
        $heartbeat_interval => sub() {
            return unless exists $connections{$conn_id};
            my $conn = $connections{$conn_id};
            $conn->{heartbeat_count}++;

            # Send heartbeat as a JSON-RPC 2.0 notification
            $c->write(
                "event: message\ndata: "
                  . encode_json(
                    {
                        jsonrpc => "2.0",
                        method  => "heartbeat",
                        params  => {
                            count => $conn->{heartbeat_count}
                        }
                    }
                  )
                  . "\n\n"
            );
            app->log->debug( "Heartbeat #"
                  . $conn->{heartbeat_count}
                  . " sent to $conn_id" );

            # Send debug events on every third heartbeat for visibility
            if ( $conn->{heartbeat_count} % 3 == 0 ) {
                send_event( $conn_id, 'debug',
                    { message => "Server is still running" } );
                app->log->debug( "Sent debug event on heartbeat #"
                      . $conn->{heartbeat_count} );
            }
        }
    );

    # Handle connection close
    $c->on(
        finish => sub ($c) {
            app->log->debug("SSE connection closed: $conn_id");
            delete $connections{$conn_id};
        }
    );

    # Subscribe to events for this connection
    my $cb = $events->on(
        "message.$conn_id" => sub ( $events, $event_type, $data ) {
            my $json = encode_json($data);

            # Always use 'message' as the event type for SSE events
            $c->write("event: message\ndata: $json\n\n");
            app->log->debug("Sent message event to $conn_id");
        }
    );

    # Remove event listener when connection closes
    $c->on(
        finish => sub () {
            $events->unsubscribe( "message.$conn_id" => $cb );
        }
    );

    return $c->rendered(200);
};

# HTTP POST endpoint - handles client-to-server communication
# Support connection ID in URL path
post '/messages/:conn_id' => sub ($c) {
    my $path_conn_id = $c->stash('conn_id');
    app->log->debug(
        "Received POST with connection ID in URL path: $path_conn_id")
      if $path_conn_id;

    # Continue with standard handler
    handle_messages_post( $c, $path_conn_id );
};

# Standard message endpoint
post '/messages' => sub ($c) {

    # Call the shared handler
    handle_messages_post($c);
};

# Shared handler for message POST requests
sub handle_messages_post ( $c, $path_conn_id = undef ) {

    # Set CORS headers (enhanced)
    $c->res->headers->header( 'Access-Control-Allow-Origin' => '*' );
    $c->res->headers->header(
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS' );
    $c->res->headers->header(
        'Access-Control-Allow-Headers' => 'Content-Type, X-Connection-ID' );

# Get connection ID from multiple possible sources (path, headers, query parameters)
    my $conn_id =
         $path_conn_id
      || $c->req->headers->header('X-Connection-ID')
      || $c->param('connection_id')
      || $c->param('connectionId')
      || $c->param('id');

    # Enhanced debugging for connection ID
    my $request_url = $c->req->url;
    app->log->debug( "Received POST to " . $request_url->to_string() );
    app->log->debug( "Request body: " . $c->req->body );
    app->log->debug(
        "Headers: "
          . join( ", ",
            map { "$_: " . $c->req->headers->header($_) }
              $c->req->headers->names )
    );
    app->log->debug( "Connection ID from request: " . ( $conn_id // 'undef' ) );

    unless ( $conn_id && exists $connections{$conn_id} ) {
        app->log->debug(
            "Invalid or missing connection ID: " . ( $conn_id // 'undef' ) );
        return $c->render(
            json => {
                jsonrpc => '2.0',
                error   => {
                    code    => -32000,
                    message => 'Invalid connection ID'
                },
                id => undef
            },
            status => 400
        );
    }

    # Parse JSON-RPC message
    my $message;
    try {
        $message = decode_json( $c->req->body );
        app->log->debug( "Received message from client: " . $c->req->body );
    }
    catch ($e) {
        app->log->debug("Error parsing JSON: $e");
        return $c->render(
            json => {
                jsonrpc => '2.0',
                error   => {
                    code    => -32700,
                    message => 'Parse error'
                },
                id => undef
            },
            status => 400
        );
    }

    # Validate JSON-RPC message
    unless ( $message->{jsonrpc} && $message->{jsonrpc} eq '2.0' ) {
        app->log->debug("Invalid JSON-RPC version");
        return $c->render(
            json => {
                jsonrpc => '2.0',
                error   => {
                    code    => -32600,
                    message => 'Invalid Request'
                },
                id => $message->{id} // 0
            },
            status => 400
        );
    }

    # Handle JSON-RPC request
    if ( $message->{method} ) {
        app->log->debug( "Handling method: " . $message->{method} );
        handle_request( $conn_id, $message );
        return $c->render( json => { status => 'ok' } );
    }
    else {
        app->log->debug("Invalid request format: missing method");
        return $c->render(
            json => {
                jsonrpc => '2.0',
                error   => {
                    code    => -32600,
                    message => 'Invalid Request'
                },
                id => $message->{id} // 0
            },
            status => 400
        );
    }
}

# Handle OPTIONS requests for CORS (main endpoint)
options '/messages' => sub ($c) {
    handle_options_request($c);
};

# Handle OPTIONS requests for URL with connection ID
options '/messages/:conn_id' => sub ($c) {
    my $conn_id = $c->stash('conn_id');
    app->log->debug(
        "Received OPTIONS with connection ID in URL path: $conn_id");
    handle_options_request($c);
};

# Shared handler for OPTIONS requests
sub handle_options_request ($c) {
    $c->res->headers->header( 'Access-Control-Allow-Origin' => '*' );
    $c->res->headers->header(
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' =>
          'Content-Type, X-Connection-ID, Content-Length' );
    app->log->debug("Handled OPTIONS request to /messages");
    $c->render( text => '', status => 200 );
}

# Function to send event to a specific connection
sub send_event ( $conn_id, $event_type, $data ) {

    # If this is a debug message, convert it to a proper JSON-RPC notification
    if (   $event_type eq 'debug'
        && ref($data) eq 'HASH'
        && exists $data->{message} )
    {
        $data = {
            jsonrpc => '2.0',
            method  => 'debug',
            params  => {
                message => $data->{message}
            }
        };
    }

    # Always use 'message' as the event type for SSE events
    $events->emit( "message.$conn_id", 'message', $data );
}

# Handle JSON-RPC requests
sub handle_request ( $conn_id, $request ) {

    # Extra debugging for request handling
    app->log->debug("handle_request called with connection ID: $conn_id");
    app->log->debug( "Request details: " . encode_json($request) );

    my $method = $request->{method};
    my $id     = $request->{id};

    if ( $method eq 'initialize' ) {
        handle_initialize( $conn_id, $request );
    }
    elsif ( $method eq 'tools/list' ) {
        handle_list_tools( $conn_id, $request );
    }
    elsif ( $method eq 'tools/call' ) {
        handle_call_tool( $conn_id, $request );
    }
    else {
        send_event(
            $conn_id,
            'message',
            {
                jsonrpc => '2.0',
                id      => $id,
                error   => {
                    code    => -32601,
                    message => "Method not found: $method"
                }
            }
        );
    }
}

# Handle initialize request
sub handle_initialize ( $conn_id, $request ) {
    app->log->debug("Handling initialize request");

    my $response = {
        jsonrpc => '2.0',
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

    send_event( $conn_id, 'message', $response );

    # Send initialized notification
    my $notification = {
        jsonrpc => '2.0',
        method  => 'initialized',
        params  => {}
    };

    send_event( $conn_id, 'message', $notification );
}

# Handle tools/list request
sub handle_list_tools ( $conn_id, $request ) {
    app->log->debug("Handling tools/list request");

    my $response = {
        jsonrpc => '2.0',
        id      => $request->{id},
        result  => {
            tools => [
                {
                    name        => 'calculate',
                    description => 'Perform basic mathematical operations',
                    inputSchema => {
                        type       => 'object',
                        properties => {
                            operation => {
                                type => 'string',
                                enum =>
                                  [ 'add', 'subtract', 'multiply', 'divide' ],
                                description =>
                                  'Mathematical operation to perform'
                            },
                            a => {
                                type        => 'number',
                                description => 'First operand'
                            },
                            b => {
                                type        => 'number',
                                description => 'Second operand'
                            }
                        },
                        required => [ 'operation', 'a', 'b' ]
                    }
                }
            ]
        }
    };

    send_event( $conn_id, 'message', $response );
}

# Handle tools/call request
sub handle_call_tool ( $conn_id, $request ) {
    app->log->debug("Handling tools/call request");

    my $name = $request->{params}{name};
    my $args = $request->{params}{arguments};

    if ( $name ne 'calculate' ) {
        send_event(
            $conn_id,
            'message',
            {
                jsonrpc => '2.0',
                id      => $request->{id},
                error   => {
                    code    => -32601,
                    message => "Tool not found: $name"
                }
            }
        );
        return;
    }

    try {
        my $operation = $args->{operation};
        my $a         = $args->{a};
        my $b         = $args->{b};

        my $result;
        if ( $operation eq 'add' ) {
            $result = $a + $b;
        }
        elsif ( $operation eq 'subtract' ) {
            $result = $a - $b;
        }
        elsif ( $operation eq 'multiply' ) {
            $result = $a * $b;
        }
        elsif ( $operation eq 'divide' ) {
            if ( $b == 0 ) {
                die "Division by zero";
            }
            $result = $a / $b;
        }
        else {
            die "Unknown operation: $operation";
        }

        send_event(
            $conn_id,
            'message',
            {
                jsonrpc => '2.0',
                id      => $request->{id},
                result  => {
                    isError => JSON::PP::false,
                    content => [
                        {
                            type => 'text',
                            text => "$result"
                        }
                    ]
                }
            }
        );
    }
    catch ($e) {
        my $error_message = $e;
        $error_message =~ s/ at .*? line \d+.*//;    # Remove Perl line info

        send_event(
            $conn_id,
            'message',
            {
                jsonrpc => '2.0',
                id      => $request->{id},
                result  => {
                    isError => JSON::PP::true,
                    content => [
                        {
                            type => 'text',
                            text => "Error: $error_message"
                        }
                    ]
                }
            }
        );
    }
}

# Start the application
app->start( 'daemon', '-l', 'http://*:3001' );
