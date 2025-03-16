#!/usr/bin/env node

/**
 * Simple MCP Server Implementation
 * This server implements a basic calculator tool without using any MCP SDK
 */

// Protocol constants
const PROTOCOL_VERSION = "2024-11-05";
const SERVER_NAME = "simple-calculator";
const SERVER_VERSION = "1.0.0";

// For message IDs
let messageId = 1;

// Read from stdin
process.stdin.setEncoding('utf8');
let buffer = '';

process.stdin.on('data', (chunk) => {
  buffer += chunk;
  processBuffer();
});

// Process the buffer to extract complete JSON-RPC messages
function processBuffer() {
  let newlineIndex;
  while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, newlineIndex);
    buffer = buffer.slice(newlineIndex + 1);
    
    try {
      const message = JSON.parse(line);
      handleMessage(message);
    } catch (error) {
      sendError(-32700, "Parse error", null);
    }
  }
}

// Handle incoming messages
function handleMessage(message) {
  if (!message.jsonrpc || message.jsonrpc !== "2.0") {
    sendError(-32600, "Invalid Request", message.id);
    return;
  }

  // Request handling
  if (message.method) {
    handleRequest(message);
  } 
  // Response handling (we're not expecting responses in this simple server)
  else if (message.hasOwnProperty('result') || message.hasOwnProperty('error')) {
    // In a more complex implementation, handle responses here
  } 
  // Invalid message
  else {
    sendError(-32600, "Invalid Request", message.id);
  }
}

// Handle incoming requests
function handleRequest(request) {
  switch (request.method) {
    case "initialize":
      handleInitialize(request);
      break;
    case "tools/list":
      handleListTools(request);
      break;
    case "tools/call":
      handleCallTool(request);
      break;
    default:
      sendError(-32601, `Method not found: ${request.method}`, request.id);
      break;
  }
}

// Handle initialize request
function handleInitialize(request) {
  const response = {
    jsonrpc: "2.0",
    id: request.id,
    result: {
      protocolVersion: PROTOCOL_VERSION,
      serverInfo: {
        name: SERVER_NAME,
        version: SERVER_VERSION
      },
      capabilities: {
        tools: {}
      }
    }
  };
  
  sendMessage(response);
  
  // Send initialized notification after successful initialization
  const notification = {
    jsonrpc: "2.0",
    method: "initialized",
    params: {}
  };
  
  sendMessage(notification);
}

// Handle tools/list request
function handleListTools(request) {
  const response = {
    jsonrpc: "2.0",
    id: request.id,
    result: {
      tools: [
        {
          name: "calculate",
          description: "Perform basic mathematical operations",
          inputSchema: {
            type: "object",
            properties: {
              operation: {
                type: "string",
                enum: ["add", "subtract", "multiply", "divide"],
                description: "Mathematical operation to perform"
              },
              a: {
                type: "number",
                description: "First operand"
              },
              b: {
                type: "number",
                description: "Second operand"
              }
            },
            required: ["operation", "a", "b"]
          }
        }
      ]
    }
  };
  
  sendMessage(response);
}

// Handle tools/call request
function handleCallTool(request) {
  const { name, arguments: args } = request.params;
  
  if (name !== "calculate") {
    sendError(-32601, `Tool not found: ${name}`, request.id);
    return;
  }
  
  let result;
  let isError = false;
  
  try {
    const { operation, a, b } = args;
    
    switch (operation) {
      case "add":
        result = a + b;
        break;
      case "subtract":
        result = a - b;
        break;
      case "multiply":
        result = a * b;
        break;
      case "divide":
        if (b === 0) {
          throw new Error("Division by zero");
        }
        result = a / b;
        break;
      default:
        throw new Error(`Unknown operation: ${operation}`);
    }
    
    const response = {
      jsonrpc: "2.0",
      id: request.id,
      result: {
        isError: false,
        content: [
          {
            type: "text",
            text: result.toString()
          }
        ]
      }
    };
    
    sendMessage(response);
    
  } catch (error) {
    const response = {
      jsonrpc: "2.0",
      id: request.id,
      result: {
        isError: true,
        content: [
          {
            type: "text",
            text: `Error: ${error.message}`
          }
        ]
      }
    };
    
    sendMessage(response);
  }
}

// Send a JSON-RPC message
function sendMessage(message) {
  const messageJson = JSON.stringify(message);
  process.stdout.write(messageJson + '\n');
}

// Send a JSON-RPC error
function sendError(code, message, id) {
  const error = {
    jsonrpc: "2.0",
    id: id || null,
    error: {
      code: code,
      message: message
    }
  };
  
  sendMessage(error);
}

// Send logging messages to stderr for debugging
function log(message) {
  console.error(`[MCP Server] ${message}`);
}

// Optional: send a logging notification to the client
function sendLogNotification(level, message) {
  const notification = {
    jsonrpc: "2.0",
    method: "notifications/logging/message",
    params: {
      level: level, // "debug", "info", "warning", "error"
      data: message
    }
  };
  
  sendMessage(notification);
}

// Log startup information
log(`Simple MCP Calculator Server started`);
log(`Supports protocol version: ${PROTOCOL_VERSION}`);
log(`Ready to receive messages...`);
