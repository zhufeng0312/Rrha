allprojects {
    repositories {
        // 国内镜像优先。背景：dl.google.com / repo1.maven.org 在本网络下会
        // 偶发 TLS 中断（Remote host terminated the handshake），实测会让个别
        // 依赖（如 com.android.tools:play-sdk-proto）随机下载失败而中断整个构建。
        // 阿里云镜像是这两者的完整代理，直连 0.17s 即可取到，故置于前面。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // 官方源保留作为兜底（镜像未同步的新版本仍能取到）
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
