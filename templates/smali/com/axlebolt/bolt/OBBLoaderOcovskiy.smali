.class public Lcom/axlebolt/bolt/OBBLoaderOcovskiy;
.super Ljava/lang/Object;
.source "OBBLoaderOcovskiy.java"


# static fields
.field private static final EXPECTED_SIZE:I = 0x6B09BD78

.field private static final LOG_TAG:Ljava/lang/String; = "OBBLoader"

.field private static final OBB_DIR_NAME:Ljava/lang/String; = "com.pleasureprod.pleasureproject"

.field private static final OBB_FILE_NAME:Ljava/lang/String; = "main.2061.com.pleasureprod.pleasureproject.obb"

.field private static final OBB_PLACEHOLDER_NAME:Ljava/lang/String; = "main.2061.com.axlebolt.standoff2.obb"


# instance fields
.field private assetManager:Landroid/content/res/AssetManager;

.field private context:Landroid/content/Context;

.field private obbDir:Ljava/io/File;


# direct methods
.method public constructor <init>(Landroid/content/Context;)V
    .locals 4

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    if-nez p1, :cond_0

    const-string v0, "OBBLoader"

    const-string v1, "Context is null! Cannot initialize OBBLoader"

    invoke-static {v0, v1}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return-void

    :cond_0
    iput-object p1, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->context:Landroid/content/Context;

    invoke-virtual {p1}, Landroid/content/Context;->getAssets()Landroid/content/res/AssetManager;

    move-result-object v0

    iput-object v0, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->assetManager:Landroid/content/res/AssetManager;

    new-instance v0, Ljava/io/File;

    :try_start_0
    invoke-static {}, Landroid/os/Environment;->getExternalStorageDirectory()Ljava/io/File;

    move-result-object v1

    if-nez v1, :cond_1

    invoke-virtual {p1}, Landroid/content/Context;->getFilesDir()Ljava/io/File;

    move-result-object v1

    :cond_1
    const-string v2, "Android/obb"

    invoke-direct {v0, v1, v2}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    iput-object v0, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->obbDir:Ljava/io/File;

    return-void

    :catch_0
    move-exception v0

    const-string v1, "OBBLoader"

    new-instance v2, Ljava/lang/StringBuilder;

    invoke-direct {v2}, Ljava/lang/StringBuilder;-><init>()V

    const-string v3, "Error initializing OBBLoader: "

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/Exception;->getMessage()Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-static {v1, v2}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method

.method private copyAssetFile(Ljava/lang/String;Ljava/io/File;)Z
    .locals 8

    const/4 v7, 0x1

    const/4 v6, 0x0

    const/4 v0, 0x0

    const/4 v1, 0x0

    :try_start_0
    iget-object v2, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->assetManager:Landroid/content/res/AssetManager;

    if-nez v2, :cond_0

    const-string v2, "OBBLoader"

    const-string v3, "AssetManager is null!"

    invoke-static {v2, v3}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return v6

    :cond_0
    invoke-virtual {v2, p1}, Landroid/content/res/AssetManager;->open(Ljava/lang/String;)Ljava/io/InputStream;

    move-result-object v0

    if-nez v0, :cond_1

    const-string v2, "OBBLoader"

    const-string v3, "Failed to open asset stream!"

    invoke-static {v2, v3}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return v6

    :cond_1
    invoke-virtual {p2}, Ljava/io/File;->getParentFile()Ljava/io/File;

    move-result-object v3

    if-eqz v3, :cond_2

    invoke-virtual {v3}, Ljava/io/File;->exists()Z

    move-result v4

    if-nez v4, :cond_2

    invoke-virtual {v3}, Ljava/io/File;->mkdirs()Z

    :cond_2
    new-instance v4, Ljava/io/FileOutputStream;

    invoke-direct {v4, p2}, Ljava/io/FileOutputStream;-><init>(Ljava/io/File;)V

    move-object v1, v4

    const/high16 v4, 0x80000

    new-array v2, v4, [B

    :goto_0
    invoke-virtual {v0, v2}, Ljava/io/InputStream;->read([B)I

    move-result v3

    if-ltz v3, :cond_4

    if-eqz v3, :cond_3

    invoke-virtual {v1, v2, v6, v3}, Ljava/io/FileOutputStream;->write([BII)V

    :cond_3
    goto :goto_0

    :cond_4
    invoke-virtual {v0}, Ljava/io/InputStream;->close()V

    invoke-virtual {v1}, Ljava/io/FileOutputStream;->close()V

    return v7
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    :catch_0
    move-exception v2

    const-string v3, "OBBLoader"

    new-instance v4, Ljava/lang/StringBuilder;

    invoke-direct {v4}, Ljava/lang/StringBuilder;-><init>()V

    const-string v5, "Error copying asset file: "

    invoke-virtual {v4, v5}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/Exception;->getMessage()Ljava/lang/String;

    move-result-object v5

    invoke-virtual {v4, v5}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v4}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v4

    invoke-static {v3, v4}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    if-eqz v0, :cond_5

    :try_start_1
    invoke-virtual {v0}, Ljava/io/InputStream;->close()V
    :try_end_1
    .catch Ljava/lang/Exception; {:try_start_1 .. :try_end_1} :catch_1

    :catch_1
    :cond_5
    if-eqz v1, :cond_6

    :try_start_2
    invoke-virtual {v1}, Ljava/io/FileOutputStream;->close()V
    :try_end_2
    .catch Ljava/lang/Exception; {:try_start_2 .. :try_end_2} :catch_2

    :catch_2
    :cond_6
    return v6
.end method

.method private createPlaceholderFile(Ljava/io/File;)Z
    .locals 4

    const/4 v3, 0x0

    if-nez p1, :cond_0

    const-string v0, "OBBLoader"

    const-string v1, "Placeholder file path is null!"

    invoke-static {v0, v1}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return v3

    :cond_0
    invoke-virtual {p1}, Ljava/io/File;->getParentFile()Ljava/io/File;

    move-result-object v0

    if-eqz v0, :cond_1

    invoke-virtual {v0}, Ljava/io/File;->exists()Z

    move-result v1

    if-nez v1, :cond_1

    invoke-virtual {v0}, Ljava/io/File;->mkdirs()Z

    :cond_1
    :try_start_0
    invoke-virtual {p1}, Ljava/io/File;->createNewFile()Z

    move-result v0

    const-string v1, "OBBLoader"

    new-instance v2, Ljava/lang/StringBuilder;

    invoke-direct {v2}, Ljava/lang/StringBuilder;-><init>()V

    const-string v3, "Placeholder file "

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    if-eqz v0, :cond_2

    const-string v3, "created"

    goto :goto_0

    :cond_2
    const-string v3, "already exists"

    :goto_0
    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v3, ": "

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {p1}, Ljava/io/File;->getAbsolutePath()Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-static {v1, v2}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    const/4 v0, 0x1

    return v0
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    :catch_0
    move-exception v0

    const-string v1, "OBBLoader"

    new-instance v2, Ljava/lang/StringBuilder;

    invoke-direct {v2}, Ljava/lang/StringBuilder;-><init>()V

    const-string v3, "Error creating placeholder: "

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/Exception;->getMessage()Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-static {v1, v2}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    const/4 v0, 0x0

    return v0
.end method

.method private getOBBDirectory()Ljava/io/File;
    .locals 3

    iget-object v0, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->context:Landroid/content/Context;

    if-eqz v0, :cond_0

    invoke-virtual {v0}, Landroid/content/Context;->getObbDir()Ljava/io/File;

    move-result-object v0

    if-eqz v0, :cond_0

    goto :goto_0

    :cond_0
    iget-object v0, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->obbDir:Ljava/io/File;

    if-eqz v0, :cond_1

    new-instance v1, Ljava/io/File;

    const-string v2, "com.pleasureprod.pleasureproject"

    invoke-direct {v1, v0, v2}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    move-object v0, v1

    :cond_1
    :goto_0
    if-eqz v0, :cond_2

    invoke-virtual {v0}, Ljava/io/File;->exists()Z

    move-result v1

    if-nez v1, :cond_2

    invoke-virtual {v0}, Ljava/io/File;->mkdirs()Z

    :cond_2
    return-object v0
.end method

.method private isOBBAlreadyLoaded()Z
    .locals 8

    const/4 v7, 0x0

    invoke-direct {p0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->getOBBDirectory()Ljava/io/File;

    move-result-object v0

    if-eqz v0, :cond_0

    new-instance v1, Ljava/io/File;

    const-string v2, "main.2061.com.pleasureprod.pleasureproject.obb"

    invoke-direct {v1, v0, v2}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/File;->exists()Z

    move-result v2

    if-eqz v2, :cond_0

    invoke-virtual {v1}, Ljava/io/File;->length()J

    move-result-wide v2

    const-wide/32 v4, 0x6B09BD78

    cmp-long v6, v2, v4

    if-ltz v6, :cond_0

    new-instance v1, Ljava/io/File;

    const-string v2, "main.2061.com.axlebolt.standoff2.obb"

    invoke-direct {v1, v0, v2}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/File;->exists()Z

    move-result v0

    return v0

    :cond_0
    return v7
.end method

.method private showLog(Ljava/lang/String;)V
    .locals 1

    const-string v0, "OBBLoader"

    invoke-static {v0, p1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method


# virtual methods
.method public loadOBB()Z
    .locals 9

    const/4 v8, 0x0

    const/4 v7, 0x1

    iget-object v0, p0, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->obbDir:Ljava/io/File;

    if-nez v0, :cond_0

    const-string v0, "OBBLoader"

    const-string v1, "OBB directory is null! Skipping loading..."

    invoke-static {v0, v1}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    return v8

    :cond_0
    invoke-direct {p0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->isOBBAlreadyLoaded()Z

    move-result v0

    if-eqz v0, :cond_1

    const-string v0, "OBB already loaded, skipping..."

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v7

    :cond_1
    const-string v0, "Starting OBB loading process..."

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    invoke-direct {p0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->getOBBDirectory()Ljava/io/File;

    move-result-object v0

    if-nez v0, :cond_2

    const-string v1, "Failed to resolve OBB directory"

    invoke-direct {p0, v1}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v8

    :cond_2
    new-instance v1, Ljava/io/File;

    const-string v2, "main.2061.com.pleasureprod.pleasureproject.obb"

    invoke-direct {v1, v0, v2}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    :try_start_0
    const-string v2, "main.2061.com.pleasureprod.pleasureproject.obb"

    invoke-direct {p0, v2, v1}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->copyAssetFile(Ljava/lang/String;Ljava/io/File;)Z

    move-result v2

    if-nez v2, :cond_3

    const-string v0, "Failed to copy OBB file from assets"

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v8

    :cond_3
    invoke-virtual {v1}, Ljava/io/File;->length()J

    move-result-wide v2

    const-wide/32 v4, 0x6B09BD78

    cmp-long v6, v2, v4

    if-ltz v6, :cond_5

    const-string v2, "OBB file copied successfully"

    invoke-direct {p0, v2}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    new-instance v2, Ljava/io/File;

    const-string v3, "main.2061.com.axlebolt.standoff2.obb"

    invoke-direct {v2, v0, v3}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    invoke-direct {p0, v2}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->createPlaceholderFile(Ljava/io/File;)Z

    move-result v0

    if-nez v0, :cond_4

    const-string v0, "Failed to create placeholder file"

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v8

    :cond_4
    const-string v0, "OBB loading completed!"

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v7

    :cond_5
    new-instance v0, Ljava/lang/StringBuilder;

    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    const-string v2, "Copied OBB is incomplete, size="

    invoke-virtual {v0, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v1}, Ljava/io/File;->length()J

    move-result-wide v2

    invoke-virtual {v0, v2, v3}, Ljava/lang/StringBuilder;->append(J)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-direct {p0, v0}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/File;->delete()Z
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    return v8

    :catch_0
    move-exception v0

    new-instance v1, Ljava/lang/StringBuilder;

    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V

    const-string v2, "Exception during OBB loading: "

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/Exception;->getMessage()Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v1

    invoke-direct {p0, v1}, Lcom/axlebolt/bolt/OBBLoaderOcovskiy;->showLog(Ljava/lang/String;)V

    return v8
.end method
