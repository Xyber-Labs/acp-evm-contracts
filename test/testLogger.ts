import dotenv from "dotenv"
dotenv.config()

const DEBUG = process.env.DEBUG || false
console.log("DEBUG logs: ", DEBUG)

// log any amount of args
async function log(...args: any[]) {
    // console.log(...args)
    if (DEBUG === "true") {
        console.log(...args)
    }
}

export { 
    log
}