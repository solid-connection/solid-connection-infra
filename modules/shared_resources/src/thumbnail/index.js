const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");

const s3 = new S3Client({ region: "ap-northeast-2" });
const SOURCE_PREFIX = "chat/files/";
const THUMBNAIL_PREFIX = "chat/thumbnails/";
const SUPPORTED_IMAGE_EXTENSIONS = new Set([".jpg", ".jpeg", ".png", ".webp"]);

exports.handler = async (event) => {
    console.log("Event received:", JSON.stringify(event, null, 2));

    const records = event?.Records ?? [];
    if (records.length === 0) {
        console.log("No S3 records found. Skipping.");
        return { statusCode: 200, body: "No S3 records found" };
    }

    const results = [];
    for (const record of records) {
        results.push(await createThumbnail(record));
    }

    return {
        statusCode: 200,
        body: JSON.stringify({ results }),
    };
};

async function createThumbnail(record) {
    const bucket = record?.s3?.bucket?.name;
    const objectKey = record?.s3?.object?.key;

    if (!bucket || !objectKey) {
        console.log("Invalid S3 record. Skipping.");
        return { skipped: true, reason: "Invalid S3 record" };
    }

    const key = decodeURIComponent(objectKey.replace(/\+/g, " "));
    console.log(`Processing file: ${key} from bucket: ${bucket}`);

    if (!key.startsWith(SOURCE_PREFIX)) {
        console.log("Not a chat file, skipping");
        return { skipped: true, reason: "Not a chat file", key };
    }

    const extension = getExtension(key);
    if (!SUPPORTED_IMAGE_EXTENSIONS.has(extension)) {
        console.log("Not an image file, skipping");
        return { skipped: true, reason: "Not an image file", key };
    }

    if (key.includes("_thumb")) {
        console.log("Already a thumbnail, skipping");
        return { skipped: true, reason: "Already a thumbnail", key };
    }

    const response = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    const imageBuffer = await streamToBuffer(response.Body);

    const thumbnailBuffer = await createThumbnailBuffer(imageBuffer, extension);

    const fileName = key.split("/").pop();
    const nameWithoutExt = fileName.slice(0, -extension.length);
    const thumbnailKey = `${THUMBNAIL_PREFIX}${nameWithoutExt}_thumb${extension}`;

    await s3.send(new PutObjectCommand({
        Bucket: bucket,
        Key: thumbnailKey,
        Body: thumbnailBuffer,
        ContentType: getContentType(extension),
        Metadata: {
            "original-key": key,
            "generated-by": "thumbnail-lambda",
        },
    }));

    console.log(`Thumbnail created successfully: ${thumbnailKey}`);

    return {
        skipped: false,
        original: key,
        thumbnail: thumbnailKey,
        thumbnailSize: thumbnailBuffer.length,
    };
}

function getExtension(key) {
    const dotIndex = key.lastIndexOf(".");
    return dotIndex === -1 ? "" : key.slice(dotIndex).toLowerCase();
}

async function createThumbnailBuffer(imageBuffer, extension) {
    const image = sharp(imageBuffer).resize(200, 200, {
        fit: "inside",
        withoutEnlargement: true,
    });

    switch (extension) {
        case ".jpg":
        case ".jpeg":
            return image.jpeg({ quality: 85 }).toBuffer();
        case ".png":
            return image.png().toBuffer();
        case ".webp":
            return image.webp({ quality: 85 }).toBuffer();
        default:
            throw new Error(`Unsupported image extension: ${extension}`);
    }
}

function getContentType(extension) {
    switch (extension) {
        case ".jpg":
        case ".jpeg":
            return "image/jpeg";
        case ".png":
            return "image/png";
        case ".webp":
            return "image/webp";
        default:
            throw new Error(`Unsupported image extension: ${extension}`);
    }
}

async function streamToBuffer(stream) {
    const chunks = [];
    for await (const chunk of stream) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return Buffer.concat(chunks);
}
