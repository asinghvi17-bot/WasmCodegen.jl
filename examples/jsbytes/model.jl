# Bytes for JavaScript: a message the program builds (as a dashboard's update, a few hundred
# bytes of MsgPack, would be) given to a function of the page's own, `page.message`, in one
# call (`Config(import_libraries = ["page"])`); and, to compare, read by the page 4 bytes per
# call of an export, as a module had to before.

const MESSAGE = UInt8[]

"Build a message of `n` bytes (a pattern the page can check); its length."
function build_message(n::Int32)
    resize!(MESSAGE, n)
    for i in 1:n
        MESSAGE[i] = (i * 7 + 3) % UInt8
    end
    return Int32(length(MESSAGE))
end

"Give the message to the page: `page.message(offset, length)`, its bytes in the module's memory."
send_message() = (ccall((:message, "page"), Cvoid, (Vector{UInt8},), MESSAGE); nothing)

"Give the page a text: `page.log(offset, length)`, its UTF-8 bytes."
send_text(n::Int32) = (ccall((:log, "page"), Cvoid, (String,), string("a message of ", n, " bytes")); nothing)

"The message's 4 bytes from `4i - 3`, little-endian (zeros past its end): reading it by calls."
function message_word(i::Int32)
    w = UInt32(0)
    for k in 0:3
        j = 4 * (Int(i) - 1) + k + 1
        j <= length(MESSAGE) && (w |= UInt32(MESSAGE[j]) << (8k))
    end
    return w % Int32
end

const ENTRIES = [(build_message, (Int32,)), (send_message, ()), (send_text, (Int32,)), (message_word, (Int32,))]
