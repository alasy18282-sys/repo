.class public Lcom/pleasureprod/pleasureproject/DnsHook;
.super Ljava/lang/Object;


# direct methods
.method public static init()V
    .locals 2

    :try_start_0
    const-string v0, "getaddrhook"

    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V

    invoke-static {}, Lcom/pleasureprod/pleasureproject/DnsHook;->nativeInit()V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    return-void
.end method

.method private static native nativeInit()V
.end method
